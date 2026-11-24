import AppKit
import Carbon

struct BrightnessKeyPress {
    let id: Int
    let action: HotkeyAction
    let down: Bool

    static func decode(type: NSEvent.EventType, keyCode: UInt16 = 0, subtype: Int16 = 0,
                       data1: Int = 0, modifiers: NSEvent.ModifierFlags = []) -> Self? {
        let down: Bool
        let action: HotkeyAction
        let id: Int
        switch type {
        case .keyDown, .keyUp:
            // Some keyboards deliver brightness as keyDown/keyUp codes 144/145,
            // rather than NX_SYSDEFINED. Fn switches these to ordinary F1/F2.
            switch Int(keyCode) {
            case kVK_F1, 145: action = .decrease
            case kVK_F2, 144: action = .increase
            default: return nil
            }
            down = type == .keyDown
            id = Int(keyCode)
        case .systemDefined:
            // NX_SUBTYPE_AUX_CONTROL_BUTTONS; NX_KEYTYPE_BRIGHTNESS_UP/DOWN.
            guard subtype == 8 else { return nil }
            let key = (data1 >> 16) & 0xffff
            let state = (data1 >> 8) & 0xff
            guard (key == 2 || key == 3), (state == 0x0a || state == 0x0b) else { return nil }
            down = state == 0x0a
            action = key == 2 ? .increase : .decrease
            id = 1000 + key
        default: return nil
        }
        if down && !modifiers.intersection([.command, .control, .option, .shift]).isEmpty { return nil }
        return Self(id: id, action: action, down: down)
    }
}

struct BrightnessKeyRouting {
    private var held = Set<Int>()

    mutating func route(_ press: BrightnessKeyPress, available: Bool) -> (consume: Bool, action: HotkeyAction?) {
        if !press.down { return (held.remove(press.id) != nil, nil) }
        guard available else { return (false, nil) }
        held.insert(press.id)
        return (true, press.action)
    }
}

enum HotkeyAction: UInt32, CaseIterable {
    case recover = 1, increase, decrease, left, right, maximize, center, previous, next
    case topThird, bottomTwoThirds
    var key: UInt32 {
        switch self {
        case .recover: UInt32(kVK_ANSI_B)
        case .increase: UInt32(kVK_UpArrow)
        case .decrease: UInt32(kVK_DownArrow)
        case .left: UInt32(kVK_LeftArrow)
        case .right: UInt32(kVK_RightArrow)
        case .maximize: UInt32(kVK_ANSI_M)
        case .center: UInt32(kVK_ANSI_C)
        case .previous: UInt32(kVK_ANSI_Comma)
        case .next: UInt32(kVK_ANSI_Period)
        case .topThird: UInt32(kVK_UpArrow)
        case .bottomTwoThirds: UInt32(kVK_DownArrow)
        }
    }

    var modifiers: UInt32 {
        UInt32(controlKey | optionKey) | (rawValue <= 3 ? UInt32(cmdKey) : 0)
    }

    var title: LocalizedStringResource {
        switch self {
        case .recover: "紧急恢复"
        case .increase: "提高组亮度"
        case .decrease: "降低组亮度"
        case .left: "左半屏"
        case .right: "右半屏"
        case .maximize: "最大化"
        case .center: "居中"
        case .previous: "上一台显示器"
        case .next: "下一台显示器"
        case .topThird: "上三分之一"
        case .bottomTwoThirds: "下三分之二"
        }
    }
}

@MainActor final class HotkeyService {
    nonisolated static let signature: OSType = 0x4454434C
    static let keys: [(UInt32, String)] = [
        (126, "↑"), (125, "↓"), (123, "←"), (124, "→"), (43, ","), (47, "."),
        (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"),
        (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"),
        (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"),
        (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z")
    ]
    private var handler: EventHandlerRef?
    private var registered = [HotkeyAction: EventHotKeyRef]()
    var onAction: ((HotkeyAction) -> Void)?
    var canHandleBrightness: ((CGPoint) -> Bool)?
    var onBrightnessKey: ((HotkeyAction, CGPoint) -> Void)?
    private var brightnessTap: CFMachPort?
    private var brightnessSource: CFRunLoopSource?
    private var brightnessRouting = BrightnessKeyRouting()
    private var brightnessMaintenance: Task<Void, Never>?
    private var brightnessAuthorization: (() -> Bool)?
    private var brightnessSessionActive = true
    var onBrightnessKeysChanged: ((Bool) -> Void)?
    var brightnessKeysActive: Bool {
        guard let brightnessTap, CFMachPortIsValid(brightnessTap),
              let brightnessSource, CFRunLoopSourceIsValid(brightnessSource) else { return false }
        return CGEvent.tapIsEnabled(tap: brightnessTap)
    }

    func startBrightnessKeyMaintenance(authorization: @escaping () -> Bool) {
        brightnessAuthorization = authorization
        brightnessSessionActive = true
        refreshBrightnessKeys()
        guard brightnessMaintenance == nil else { return }
        brightnessMaintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.refreshBrightnessKeys()
            }
        }
    }

    func refreshBrightnessKeys(rebuild: Bool = false) {
        if rebuild { stopBrightnessKeys() }
        updateBrightnessKeys(authorized: brightnessSessionActive && brightnessAuthorization?() == true)
        onBrightnessKeysChanged?(brightnessKeysActive)
    }

    func setBrightnessSessionActive(_ active: Bool) {
        brightnessSessionActive = active
        refreshBrightnessKeys(rebuild: active)
    }

    func updateBrightnessKeys(authorized: Bool) {
        guard authorized else { stopBrightnessKeys(); return }
        if let brightnessTap, CFMachPortIsValid(brightnessTap),
           let brightnessSource, CFRunLoopSourceIsValid(brightnessSource) {
            if !CGEvent.tapIsEnabled(tap: brightnessTap) {
                brightnessRouting = BrightnessKeyRouting()
                CGEvent.tapEnable(tap: brightnessTap, enable: true)
            }
            if CGEvent.tapIsEnabled(tap: brightnessTap) { return }
        }
        // Invalid ports/sources cannot be repaired by tapEnable; replace both together.
        stopBrightnessKeys()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) | (CGEventMask(1) << 14)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let consume = MainActor.assumeIsolated {
                    let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        service.brightnessRouting = BrightnessKeyRouting()
                        if let tap = service.brightnessTap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return false
                    }
                    guard let native = NSEvent(cgEvent: event) else { return false }
                    let press: BrightnessKeyPress?
                    if native.type == .systemDefined {
                        press = BrightnessKeyPress.decode(type: native.type, subtype: native.subtype.rawValue,
                                                         data1: native.data1, modifiers: native.modifierFlags)
                    } else {
                        press = BrightnessKeyPress.decode(type: native.type, keyCode: native.keyCode,
                                                         modifiers: native.modifierFlags)
                    }
                    guard let press else { return false }
                    let point = NSEvent.mouseLocation
                    let result = service.brightnessRouting.route(press, available: service.canHandleBrightness?(point) == true)
                    if let action = result.action {
                        // Keep the event tap responsive; actual brightness work runs after this callback.
                        Task { @MainActor [weak service] in
                            guard service?.canHandleBrightness?(point) == true else { return }
                            service?.onBrightnessKey?(action, point)
                        }
                    }
                    return result.consume
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        brightnessTap = tap
        brightnessSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopBrightnessKeys() {
        if let brightnessTap {
            CGEvent.tapEnable(tap: brightnessTap, enable: false)
            CFMachPortInvalidate(brightnessTap)
        }
        if let brightnessSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), brightnessSource, .commonModes) }
        brightnessTap = nil
        brightnessSource = nil
        brightnessRouting = BrightnessKeyRouting()
    }

    func start() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == HotkeyService.signature,
                  let action = HotkeyAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue().onAction?(action)
            }
            return noErr
        }, 1, &type, context, &handler)
    }

    func register(_ action: HotkeyAction, key: UInt32) -> Bool {
        guard handler != nil else { return false }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let options = action == .recover ? OptionBits(kEventHotKeyExclusive) : 0
        guard RegisterEventHotKey(key, action.modifiers, id, GetApplicationEventTarget(), options, &reference) == noErr,
              let reference else { return false }
        unregister(action)
        registered[action] = reference
        return true
    }

    func unregister(_ action: HotkeyAction) {
        if let reference = registered.removeValue(forKey: action) { UnregisterEventHotKey(reference) }
    }

    func isRegistered(_ action: HotkeyAction) -> Bool { registered[action] != nil }

    func stop() {
        brightnessMaintenance?.cancel()
        brightnessMaintenance = nil
        brightnessAuthorization = nil
        stopBrightnessKeys()
        for action in Array(registered.keys) { unregister(action) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    #if APPKIT_SMOKE_TEST
    func testDisableBrightnessTap() {
        if let brightnessTap { CGEvent.tapEnable(tap: brightnessTap, enable: false) }
    }

    func testInvalidateBrightnessTap() {
        if let brightnessTap { CFMachPortInvalidate(brightnessTap) }
    }

    func testInvalidateBrightnessSource() {
        if let brightnessSource { CFRunLoopSourceInvalidate(brightnessSource) }
    }
    #endif
}

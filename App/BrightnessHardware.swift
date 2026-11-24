import AppKit
import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics

enum BrightnessPath: Sendable {
    case native
    case appleNative
    case ddc(UInt32, UInt16)
    case experimentalDDC(UInt16)
}

struct HardwareReading: Sendable {
    let path: BrightnessPath
    let value: Double
}

struct HardwareDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let builtIn: Bool

    init(_ id: CGDirectDisplayID) {
        self.id = id
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id)
        builtIn = CGDisplayIsBuiltin(id) != 0
    }

    var isCurrent: Bool { CGDisplayIsOnline(id) != 0 && self == HardwareDisplay(id) }
}

protocol BrightnessProvider: Sendable {
    func probe(_ display: HardwareDisplay, experimental: Bool) async -> HardwareReading?
    func write(_ value: Double, to display: HardwareDisplay, path: BrightnessPath) async -> Double?
}

actor BrightnessHardware: BrightnessProvider {
    private typealias NativeGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias NativeSet = @convention(c) (UInt32, Float) -> Int32
    private let nativeLibrary = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL
    )
    private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVTransfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private let ioLibrary = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL)
    private let brightnessKey = kIODisplayBrightnessKey as CFString

    func probe(_ display: HardwareDisplay, experimental: Bool) -> HardwareReading? {
        guard display.isCurrent else { return nil }
        let service = framebuffer(for: display)
        defer { if service != 0 { IOObjectRelease(service) } }
        var value: Float = -1
        if service != 0, IODisplayGetFloatParameter(service, 0, brightnessKey, &value) == 0,
           (0...1).contains(value) {
            return HardwareReading(path: .native, value: Double(value) * 100)
        }
        // Built-in panels need DisplayServices on current Apple Silicon systems.
        // External Apple displays and DDC remain behind the compatibility setting.
        if display.builtIn || (experimental && display.vendor == 0x610),
           let library = nativeLibrary,
           let get = dlsym(library, "DisplayServicesGetBrightness"),
           dlsym(library, "DisplayServicesSetBrightness") != nil,
           unsafeBitCast(get, to: NativeGet.self)(display.id, &value) == 0, (0...1).contains(value) {
            return HardwareReading(path: .appleNative, value: Double(value) * 100)
        }
        guard !display.builtIn else { return nil }
        if service == 0 { return experimental ? probeAV(display) : nil }
        var count: UInt32 = 0
        guard IOFBGetI2CInterfaceCount(service, &count) == 0 else { return experimental ? probeAV(display) : nil }
        for bus in 0..<count {
            if let reply = transaction(service, bus: bus, payload: [0x01, 0x10], read: true),
               let level = decodeVCP(reply) {
                return HardwareReading(path: .ddc(bus, level.maximum),
                                       value: Double(level.current) / Double(level.maximum) * 100)
            }
        }
        return experimental ? probeAV(display) : nil
    }

    func write(_ value: Double, to display: HardwareDisplay, path: BrightnessPath) -> Double? {
        guard (1...100).contains(value), display.isCurrent, CGDisplayIsAsleep(display.id) == 0,
              !Task.isCancelled else { return nil }
        if case let .experimentalDDC(maximum) = path {
            return writeAV(value, display: display, maximum: maximum)
        }
        let service = framebuffer(for: display)
        defer { if service != 0 { IOObjectRelease(service) } }
        switch path {
        case .native:
            let normalized = Float(value / 100)
            guard service != 0, IODisplaySetFloatParameter(service, 0, brightnessKey, normalized) == 0 else { return nil }
            return value
        case .appleNative:
            let normalized = Float(value / 100)
            guard display.builtIn || display.vendor == 0x610, let library = nativeLibrary,
                  let set = dlsym(library, "DisplayServicesSetBrightness"),
                  let get = dlsym(library, "DisplayServicesGetBrightness"),
                  unsafeBitCast(set, to: NativeSet.self)(display.id, normalized) == 0 else { return nil }
            var actual: Float = -1
            guard unsafeBitCast(get, to: NativeGet.self)(display.id, &actual) == 0,
                  (0...1).contains(actual) else { return nil }
            return Double(actual) * 100
        case .experimentalDDC: return nil
        case let .ddc(bus, maximum):
            guard service != 0 else { return nil }
            let target = max(1, UInt16((value * Double(maximum) / 100).rounded()))
            guard transaction(service, bus: bus, payload: [0x03, 0x10, UInt8(target >> 8),
                                                          UInt8(target & 255)], read: false) != nil else { return nil }
            usleep(55_000)
            guard display.isCurrent, let reply = transaction(service, bus: bus, payload: [0x01, 0x10], read: true),
                  let level = decodeVCP(reply), level.current == target, level.maximum == maximum else { return nil }
            return Double(level.current) / Double(level.maximum) * 100
        }
    }

    private func probeAV(_ display: HardwareDisplay) -> HardwareReading? {
        guard let service = avService(display) else { return nil }
        for _ in 0..<3 {
            guard !Task.isCancelled, display.isCurrent else { return nil }
            if let level = readAV(service, display: display) {
                return HardwareReading(path: .experimentalDDC(level.maximum),
                                       value: Double(level.current) / Double(level.maximum) * 100)
            }
            usleep(40_000)
        }
        return nil
    }

    private func writeAV(_ value: Double, display: HardwareDisplay, maximum: UInt16) -> Double? {
        guard let service = avService(display), !Task.isCancelled else { return nil }
        let target = max(1, UInt16((value * Double(maximum) / 100).rounded()))
        var message: [UInt8] = [0x84, 0x03, 0x10, UInt8(target >> 8), UInt8(target & 255)]
        message.append(message.reduce(0x6e ^ 0x51, ^))
        guard sendAVRequest(service, display: display, message: &message) else { return nil }
        usleep(55_000)
        for _ in 0..<3 {
            guard !Task.isCancelled, display.isCurrent else { return nil }
            if let level = readAV(service, display: display), level.current == target, level.maximum == maximum {
                return Double(level.current) / Double(level.maximum) * 100
            }
            usleep(40_000)
        }
        return nil
    }

    private func readAV(_ service: CFTypeRef, display: HardwareDisplay) -> (current: UInt16, maximum: UInt16)? {
        var message: [UInt8] = [0x82, 0x01, 0x10]
        message.append(message.reduce(0x6e, ^))
        guard sendAVRequest(service, display: display, message: &message) else { return nil }
        usleep(65_000)
        guard !Task.isCancelled, display.isCurrent, CGDisplayIsAsleep(display.id) == 0 else { return nil }
        var reply = [UInt8](repeating: 0, count: 11)
        guard avTransfer(service, symbol: "IOAVServiceReadI2C", address: 0, message: &reply) else { return nil }
        return decodeVCP(reply)
    }

    private func sendAVRequest(_ service: CFTypeRef, display: HardwareDisplay, message: inout [UInt8]) -> Bool {
        // Some Apple Silicon links require two identical requests. Get and absolute Set VCP are idempotent.
        for attempt in 0..<2 {
            guard !Task.isCancelled, display.isCurrent, CGDisplayIsAsleep(display.id) == 0,
                  avTransfer(service, symbol: "IOAVServiceWriteI2C", address: 0x51, message: &message) else { return false }
            if attempt == 0 { usleep(10_000) }
        }
        return true
    }

    private func avTransfer(_ service: CFTypeRef, symbol: String, address: UInt32,
                            message: inout [UInt8]) -> Bool {
        guard let ioLibrary, let symbol = dlsym(ioLibrary, symbol) else { return false }
        return message.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            return unsafeBitCast(symbol, to: AVTransfer.self)(service, 0x37, address, base, UInt32(bytes.count)) == 0
        }
    }

    private func avService(_ display: HardwareDisplay) -> CFTypeRef? {
        guard display.isCurrent, !display.builtIn, CGDisplayIsAsleep(display.id) == 0, let ioLibrary,
              let create = dlsym(ioLibrary, "IOAVServiceCreateWithService"),
              dlsym(ioLibrary, "IOAVServiceReadI2C") != nil,
              dlsym(ioLibrary, "IOAVServiceWriteI2C") != nil else { return nil }

        // Accept a one-to-one match only. Never infer hardware routing from display enumeration order.
        var online = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(online.count), &online, &count) == .success,
              count < online.count,
              online.prefix(Int(count)).filter({
                  CGDisplayVendorNumber($0) == display.vendor && CGDisplayModelNumber($0) == display.model &&
                  CGDisplaySerialNumber($0) == display.serial
              }).count == 1 else { return nil }

        var routes = [String]()
        for cls in ["IOMobileFramebufferShim", "AppleCLCD2"] {
            forEachService(cls) { entry in
                let attributes = registryValue(entry, "DisplayAttributes") as? [String: Any]
                guard let product = attributes?["ProductAttributes"] as? [String: Any],
                      (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value == display.vendor,
                      (product["ProductID"] as? NSNumber)?.uint32Value == display.model,
                      (product["SerialNumber"] as? NSNumber)?.uint32Value == display.serial,
                      let route = registryPath(entry).split(separator: "/").dropLast().last?.split(separator: "@").first,
                      route.hasPrefix("dispext") else { return }
                routes.append(String(route))
            }
        }
        guard Set(routes).count == 1, let route = routes.first else { return nil }
        var ids = [UInt64]()
        forEachService("DCPAVServiceProxy") { entry in
            var id: UInt64 = 0
            guard registryValue(entry, "Location") as? String == "External",
                  registryPath(entry).split(separator: "/").dropLast().last?.hasPrefix(route + ":") == true,
                  IORegistryEntryGetRegistryEntryID(entry, &id) == 0 else { return }
            ids.append(id)
        }
        guard ids.count == 1, let id = ids.first else { return nil }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return unsafeBitCast(create, to: AVCreate.self)(nil, entry)?.takeRetainedValue()
    }

    private func forEachService(_ name: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == 0 else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    private func registryValue(_ entry: io_service_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, nil, 0)?.takeRetainedValue()
    }

    private func registryPath(_ entry: io_service_t) -> String {
        var buffer = [CChar](repeating: 0, count: MemoryLayout<io_string_t>.size)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func framebuffer(for display: HardwareDisplay) -> io_service_t {
        guard display.serial != 0 else { return 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == 0 else { return 0 }
        defer { IOObjectRelease(iterator) }
        var match: io_service_t = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let info = IODisplayCreateInfoDictionary(entry, 0).takeRetainedValue() as NSDictionary
            guard (info[kDisplayVendorID] as? NSNumber)?.uint32Value == display.vendor,
                  (info[kDisplayProductID] as? NSNumber)?.uint32Value == display.model,
                  (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value == display.serial else { continue }
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == 0 else { continue }
            if match != 0 {
                IOObjectRelease(match)
                IOObjectRelease(parent)
                return 0
            }
            match = parent
        }
        return match
    }

    private func transaction(_ service: io_service_t, bus: UInt32, payload: [UInt8],
                             read: Bool) -> [UInt8]? {
        var interface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(service, bus, &interface) == 0 else { return nil }
        defer { IOObjectRelease(interface) }
        var connection: IOI2CConnectRef?
        guard IOI2CInterfaceOpen(interface, 0, &connection) == 0, let connection else { return nil }
        defer { IOI2CInterfaceClose(connection, 0) }

        var packet = [UInt8(0x51), 0x80 | UInt8(payload.count)] + payload
        packet.append(packet.reduce(0x6e, ^))
        var reply = [UInt8](repeating: 0, count: 11)
        let sent = packet.withUnsafeBytes { bytes in
            var request = IOI2CRequest()
            request.sendAddress = 0x6e
            request.sendTransactionType = UInt32(kIOI2CSimpleTransactionType)
            request.sendBytes = UInt32(bytes.count)
            request.sendBuffer = UInt(bitPattern: bytes.baseAddress)
            return IOI2CSendRequest(connection, 0, &request) == 0 && request.result == 0
        }
        guard sent else { return nil }
        guard read else { return [] }
        usleep(50_000)
        let received = reply.withUnsafeMutableBytes { bytes in
            var request = IOI2CRequest()
            request.replyAddress = 0x6f
            request.replyTransactionType = UInt32(kIOI2CSimpleTransactionType)
            request.replyBytes = UInt32(bytes.count)
            request.replyBuffer = UInt(bitPattern: bytes.baseAddress)
            return IOI2CSendRequest(connection, 0, &request) == 0 && request.result == 0 && request.replyBytes == 11
        }
        return received ? reply : nil
    }

    private func decodeVCP(_ reply: [UInt8]) -> (current: UInt16, maximum: UInt16)? {
        guard reply.count == 11, reply[0] == 0x6e, reply[1] == 0x88, reply[2] == 0x02,
              reply[3] == 0, reply[4] == 0x10, reply.reduce(0x50, ^) == 0 else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }
}

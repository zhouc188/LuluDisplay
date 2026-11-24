import SwiftUI
import ServiceManagement

private struct FloatingSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape).clipShape(shape)
        } else if #available(macOS 26.0, *) {
            content.clipShape(shape).glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).clipShape(shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.10)).allowsHitTesting(false) }
        }
    }
}

struct ControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(12)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct BrightnessNumber: View {
    let value: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: value ?? 0))
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: value)
            .frame(minWidth: 46, alignment: .trailing)
    }
}

@MainActor
final class ControlInteraction: ObservableObject {
    @Published var active = false
}

struct BrightnessControl: View {
    @Binding var value: Double
    let label: String
    let available: Bool
    var knownValue = true
    @StateObject private var interaction = ControlInteraction()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min").foregroundStyle(.secondary).accessibilityHidden(true)
            // Keep the native slider's keyboard, focus and accessibility behavior.
            Slider(value: $value, in: 0...100, step: 1, onEditingChanged: { interaction.active = $0 })
                .accessibilityLabel(label)
                .disabled(!available)
            BrightnessNumber(value: knownValue ? value : nil)
                .foregroundStyle(interaction.active ? Color.accentColor : Color.secondary)
                .scaleEffect(interaction.active && !reduceMotion ? 1.04 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.8), value: interaction.active)
        }
    }
}

struct BrightnessHUDView: View {
    let feedback: BrightnessFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(feedback.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    BrightnessNumber(value: feedback.value)
                        .accessibilityLabel("目标亮度")
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.14))
                        Capsule().fill(.primary.opacity(0.85))
                            .frame(width: geometry.size.width * min(100, max(0, feedback.value)) / 100)
                            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: feedback.value)
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FloatingSurface(cornerRadius: 26))
    }
}

struct BlackoutVerificationView: View {
    @ObservedObject var model: DesktopModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前还不是 0% 全黑").font(.headline)
            Text("为避免所有屏幕变黑后无法恢复，本次启动需要先验证恢复快捷键。")
            Text("请按 \(model.keyLabel(.recover))")
                .font(.title2.bold()).frame(maxWidth: .infinity)
            Text("验证后再次降低至 0%，参与同步的屏幕会一起全黑。首次试用会在 8 秒后恢复，也可按 F2 或恢复快捷键退出。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("取消") { model.cancelBlackoutVerification() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("恢复可视亮度") { model.recover() }
            }
        }.padding(18).frame(width: 420)
    }
}

struct PanelView: View {
    @ObservedObject var model: DesktopModel
    let settings: () -> Void
    let windowAction: (HotkeyAction) -> Void
    let width: CGFloat
    let maximumHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "display").font(.headline).accessibilityHidden(true)
                Text("LuluDisplay").font(.headline)
                Spacer()
                Text("\(model.displays.count) 台显示器").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
            Divider().padding(.horizontal, 14)
            // Scroll the whole working area. Notices and expanded calibration must not
            // push the footer outside a fixed-size AppKit panel on a small display.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ModeConfirmation(service: model.resolution)
                    if let notice = model.notice {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle").accessibilityHidden(true)
                            Text(notice).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            if !model.awaitingProof {
                                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).accessibilityLabel("关闭提示").help("关闭提示")
                            }
                        }.foregroundStyle(.orange).modifier(ControlSurface())
                    }
                    if model.displays.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("没有可用显示器", systemImage: "display.trianglebadge.exclamationmark")
                                .font(.headline)
                            Text("连接显示器后会自动更新。").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).modifier(ControlSurface())
                    } else {
                        masterControl
                        ForEach(model.displays) { DisplayCard(model: model, display: $0) }
                    }
                    LoginItemControls(model: model).font(.callout)
                }.padding(14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 10) {
                DesktopToggles(model: model, windowAction: windowAction)
                if !model.accessibilityAuthorized {
                    HStack {
                        Text("窗口布局需要辅助功能权限").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("前往授权") { model.windows.requestAccess() }.font(.caption)
                    }
                }
                HStack {
                    Button(action: settings) { Label("设置", systemImage: "gearshape") }
                        .buttonStyle(.borderless)
                    Spacer(minLength: 4)
                    Button { model.recover() } label: { Label("恢复亮度", systemImage: "sun.max") }
                        .buttonStyle(.bordered)
                        .help("立即撤去黑屏与调暗遮罩，恢复可视亮度（\(model.keyLabel(.recover))）")
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                        .buttonStyle(.borderless).padding(.horizontal, 4)
                        .accessibilityLabel("退出 LuluDisplay").help("退出 LuluDisplay")
                }.controlSize(.small)
            }.padding(14)
        }
        .frame(width: width, height: min(maximumHeight, 390 + CGFloat(min(model.displays.count, 3)) * 145))
        .modifier(FloatingSurface(cornerRadius: 28))
    }

    private var masterControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.sync ? "同步亮度" : "主屏亮度").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.sync ? "\(model.masterDisplays.count) 台参与" : (model.sourceName ?? "无主屏"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            BrightnessControl(value: Binding(get: { model.master }, set: model.setMaster),
                              label: model.sync ? "同步亮度" : "主屏亮度",
                              available: model.canAdjustMaster, knownValue: model.canAdjustMaster)
            HStack {
                Toggle("同步显示器", isOn: Binding(get: { model.sync }, set: model.setSync))
                    .toggleStyle(.switch).controlSize(.mini)
                Spacer(minLength: 4)
                Picker("主屏", selection: Binding(get: { model.source ?? 0 }, set: model.setSource)) {
                    if model.source == nil { Text("无可用显示器").tag(UInt32(0)) }
                    ForEach(model.displays.filter(\.controllable)) { Text($0.name).tag($0.id) }
                }.help("主屏用于主滑杆与同步参考").accessibilityLabel("主屏")
                    .frame(maxWidth: 190)
            }.font(.caption)
            if !model.probing.isEmpty {
                Label("正在检测显示器…", systemImage: "ellipsis.circle").font(.caption).foregroundStyle(.secondary)
            } else if model.masterDisplays.isEmpty {
                Text(model.sync ? "暂无可调节的参与屏幕，请检查下方的参与同步与调暗设置。" : "主屏当前无法调节，请检查调暗设置或选择其他主屏。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.sync ? "F1 / F2 调节参与同步的屏幕" : "F1 / F2 调节鼠标所在屏幕；此滑杆调节主屏")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.modifier(ControlSurface())
    }
}

private struct LoginItemControls: View {
    @ObservedObject var model: DesktopModel

    var body: some View {
        HStack {
            Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                .toggleStyle(.switch).controlSize(.small)
            if model.login == .requiresApproval {
                Text("等待系统批准").font(.caption).foregroundStyle(.secondary)
            }
            if model.login == .requiresApproval || model.loginError != nil {
                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error = model.loginError { Text(error).foregroundStyle(.red) }
    }
}

struct DisplayCard: View {
    @ObservedObject var model: DesktopModel
    let display: Display

    var body: some View {
        let calibration = model.calibration(display.id)
        let reading = model.readings[display.id]
        let value = model.values[display.id]
        VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: display.builtIn ? "laptopcomputer" : "display")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(display.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(CGDisplayIsAsleep(display.id) == 0 ? "已连接" : "休眠")
                        .font(.caption).foregroundStyle(.secondary)
                }
                BrightnessControl(value: Binding(get: { value ?? 100 }, set: { model.setIndividual(display, value: $0) }),
                                  label: "\(display.name) 亮度",
                                  available: model.canAdjustBrightness(display) && !model.probing.contains(display.id) && value != nil,
                                  knownValue: value != nil)
                HStack {
                    Text(pathSummary(reading, calibration: calibration, value: value))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(pathLabel(reading, calibration: calibration, value: value))
                    Spacer()
                    Toggle("参与同步", isOn: Binding(get: { calibration.participates }, set: { new in
                        model.updateCalibration(display) { $0.participates = new }
                    })).toggleStyle(.switch).controlSize(.mini).font(.caption)
                        .disabled(!display.controllable)
                }
                if let issue = model.issues[display.id] { Text(issue).font(.caption).foregroundStyle(.orange) }
                if reading == nil, calibration.software, !model.probing.contains(display.id), value != 0 {
                    Text("100% 表示无软件遮罩，硬件亮度仍由系统或显示器控制。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if display.controllable {
                    DisclosureGroup("校准与分辨率") {
                        VStack(alignment: .leading, spacing: 9) {
                            if let mode = model.resolution.current(display) {
                                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(pathLabel(reading, calibration: calibration, value: value))
                                .font(.caption).foregroundStyle(.secondary)
                            Stepper("偏移 \(Int(calibration.offset))%", value: Binding(get: { calibration.offset }, set: { new in
                                model.updateCalibration(display) { $0.offset = new }
                            }), in: -100...100, step: 1)
                            Stepper("最低 \(Int(calibration.minimum))%", value: Binding(get: { calibration.minimum }, set: { new in
                                model.updateCalibration(display) { $0.minimum = new }
                            }), in: 1...calibration.maximum, step: 1)
                            Stepper("最高 \(Int(calibration.maximum))%", value: Binding(get: { calibration.maximum }, set: { new in
                                model.updateCalibration(display) { $0.maximum = new }
                            }), in: calibration.minimum...100, step: 1)
                            Toggle("硬件不可用时使用软件调暗", isOn: Binding(get: { calibration.software }, set: { new in
                                model.updateCalibration(display) { $0.software = new }
                            }))
                            if display.identity == nil {
                                Text("无法可靠识别这台显示器，校准会在显示器重新枚举时清除。").font(.caption).foregroundStyle(.secondary)
                            }
                            ResolutionPicker(service: model.resolution, display: display,
                                             blocked: !model.overlays.blackIDs.isEmpty)
                        }.padding(.top, 6)
                    }
                }
        }.modifier(ControlSurface())
    }

    private func pathSummary(_ reading: HardwareReading?, calibration: Calibration, value: Double?) -> String {
        if !display.controllable { return "无法独立控制" }
        if model.probing.contains(display.id) { return "正在检测…" }
        if value == 0 && model.overlays.blackIDs.contains(display.id) { return "全黑" }
        if reading != nil { return "硬件亮度" }
        return calibration.software ? "软件调暗" : "亮度不可用"
    }

    private func pathLabel(_ reading: HardwareReading?, calibration: Calibration, value: Double?) -> String {
        if !display.controllable { return String(localized: "镜像或未分配独立桌面，无法单独控制") }
        if model.probing.contains(display.id) { return String(localized: "正在检测亮度能力…") }
        if value == 0 && model.overlays.blackIDs.contains(display.id) { return String(localized: "0% 全黑覆盖层") }
        switch reading?.path {
        case .native: return String(localized: "原生硬件亮度")
        case .appleNative: return display.builtIn ? String(localized: "内置屏硬件亮度")
            : String(localized: "Apple 硬件亮度（兼容模式）")
        case .ddc: return "DDC/CI"
        case .experimentalDDC: return String(localized: "DDC/CI（兼容模式）")
        case nil:
            return calibration.software ? String(localized: "软件调暗 · 100% 仅表示无遮挡，硬件亮度由系统或显示器控制")
                : String(localized: "无可用硬件亮度通道，软件调暗已停用")
        }
    }
}

struct ModeConfirmation: View {
    @ObservedObject var service: ResolutionService
    var body: some View {
        if let change = service.active {
            GroupBox {
                VStack(alignment: .leading) {
                    Text("\(change.display.name) · \(change.requested.detail)")
                    HStack {
                        Text("\(service.remaining) 秒后回退").monospacedDigit()
                        Spacer()
                        Button("立即回退") { service.rollback() }
                        Button("保留模式") { service.confirm() }.buttonStyle(.borderedProminent)
                    }
                }.font(.callout)
            }
        }
        if let issue = service.issue { Text(issue).font(.callout).foregroundStyle(.orange) }
    }
}

struct ResolutionPicker: View {
    @ObservedObject var service: ResolutionService
    let display: Display
    let blocked: Bool
    @StateObject private var interaction = ResolutionInteraction()

    var body: some View {
        let choices = service.modes(display)
        let presets = service.presetModes(display, available: choices)
        let current = service.current(display)
        let selected = current.flatMap { ResolutionSize.tiers.firstIndex(of: $0.size) }.flatMap {
            presets[$0] == nil ? nil : $0
        }
        let focused = interaction.preview ?? selected
        let enabled = service.active == nil && !blocked
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("分辨率档位").font(.subheadline)
                Spacer()
                if let focused {
                    Text(ResolutionSize.tiers[focused].label).monospacedDigit()
                    if presets[focused] == nil { Text("该显示器不支持").font(.caption).foregroundStyle(.secondary) }
                } else { Text("当前模式不在预设档位").font(.caption).foregroundStyle(.secondary) }
            }
            GeometryReader { proxy in
                let padding = 12.0
                let length = max(1, proxy.size.width - padding * 2)
                ZStack {
                    Capsule().fill(.quaternary).frame(height: 3).padding(.horizontal, padding)
                    ForEach(presets.indices, id: \.self) { index in
                        let supported = presets[index] != nil
                        Button {
                            if let mode = presets[index] { service.begin(display, mode: mode) }
                        } label: {
                            VStack(spacing: 2) {
                                Circle()
                                    .fill(focused == index && supported ? Color.accentColor :
                                          supported ? Color.secondary : Color.secondary.opacity(0.35))
                                    .frame(width: focused == index ? 12 : 7, height: focused == index ? 12 : 7)
                                    .frame(height: 14)
                                Text("\(index + 1)").font(.caption2)
                            }.frame(width: 24)
                        }.buttonStyle(.plain)
                            .disabled(!enabled || !supported)
                            .help(supported ? ResolutionSize.tiers[index].label :
                                  String(localized: "\(ResolutionSize.tiers[index].label) · 该显示器不支持"))
                            .accessibilityLabel(Text(ResolutionSize.tiers[index].label))
                            .accessibilityAddTraits(selected == index ? .isSelected : [])
                            .position(x: padding + length * Double(index) / 7, y: 16)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { event in
                    guard enabled else { return }
                    interaction.preview = Int(min(7, max(0, ((event.location.x - padding) * 7 / length).rounded())))
                }.onEnded { _ in
                    defer { interaction.preview = nil }
                    if enabled, let index = interaction.preview, let mode = presets[index] {
                        service.begin(display, mode: mode)
                    }
                })
                .focusable()
                .onMoveCommand { direction in
                    guard enabled else { return }
                    let forward = direction == .right || direction == .up
                    let anchor = selected ?? (forward ? -1 : 8)
                    let indices = forward ? Array(presets.indices) : Array(presets.indices.reversed())
                    if let index = indices.first(where: { (forward ? $0 > anchor : $0 < anchor) && presets[$0] != nil }),
                       let mode = presets[index] { service.begin(display, mode: mode) }
                }
            }.frame(height: 36)
            if presets.allSatisfy({ $0 == nil }) {
                Text("该显示器的当前布局没有可用预设档位。").font(.caption).foregroundStyle(.secondary)
            }
            Menu("系统显示模式") {
                ForEach(choices) { mode in
                    Button {
                        service.begin(display, mode: mode)
                    } label: {
                        if service.savedModeID(display) == mode.id {
                            Label(mode.detail, systemImage: "checkmark")
                        } else { Text(mode.detail) }
                    }.disabled(current?.id == mode.id)
                }
            }.disabled(!enabled || choices.isEmpty)
        }
    }
}

@MainActor private final class ResolutionInteraction: ObservableObject {
    @Published var preview: Int?
}

struct SettingsView: View {
    @ObservedObject var model: DesktopModel

    var body: some View {
        VStack(alignment: .leading) {
            ModeConfirmation(service: model.resolution)
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.orange) }
            TabView {
                displaySettings.tabItem { Label("显示器", systemImage: "display") }
                WindowSettings(model: model).tabItem { Label("窗口", systemImage: "macwindow") }
                AppearanceSettings(model: model).tabItem { Label("外观", systemImage: "paintbrush") }
                generalSettings.tabItem { Label("通用", systemImage: "gearshape") }
            }
        }
        .padding(14)
        .frame(minWidth: 550, minHeight: 410)
        .onAppear { model.refreshLoginStatus() }
    }

    private var displaySettings: some View {
        Form {
            Section("亮度同步") {
                Picker("同步模式", selection: Binding(get: { model.relative }, set: model.setRelative)) {
                    Text("相对同步").tag(true)
                    Text("绝对同步").tag(false)
                }.pickerStyle(.segmented)
                Toggle("外接屏跟随内置屏亮度",
                       isOn: Binding(get: { model.followSystemBrightness }, set: model.setFollowSystemBrightness))
                    .disabled(!model.canFollowSystemBrightness && !model.followSystemBrightness)
                Text(model.canFollowSystemBrightness
                     ? "约每 2 秒读取一次内置屏亮度，可跟随自动调光及手动调整。"
                     : "开启同步后，选择支持硬件亮度的内置主屏，并让至少一台外接屏参与同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("亮度控制") {
                Toggle("软件调暗平滑过渡", isOn: Binding(get: { model.smooth }, set: model.setSmooth))
                Toggle("启用外接 Apple 显示器及 DDC 兼容探测",
                       isOn: Binding(get: { model.experimental }, set: model.setExperimental))
                Text("内置屏自动检测硬件亮度通道。外接兼容探测使用未公开接口，硬件不可用时可使用软件调暗。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.displays.isEmpty {
                Section("已连接的显示器") {
                    ForEach(model.displays) { DisplayCard(model: model, display: $0) }
                }
            }
        }.formStyle(.grouped)
    }

    private var generalSettings: some View {
        Form {
            Section("启动") { LoginItemControls(model: model) }
            Section("键盘快捷键") {
                Text(model.brightnessKeysActive
                     ? "亮度键已启用，每次调节 5%。"
                     : "亮度键尚未启用，请检查辅助功能授权。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    Picker(selection: Binding(get: { model.keyCodes[action] ?? action.key },
                                              set: { model.setKey(action, $0) })) {
                        ForEach(HotkeyService.keys, id: \.0) { item in
                            Text((action.rawValue <= 3 ? "⌃⌥⌘" : "⌃⌥") + item.1).tag(item.0)
                        }
                    } label: { Text(action.title) }
                    if model.conflicts.contains(action) {
                        Text("此快捷键未注册，可能存在冲突。").foregroundStyle(.orange)
                    }
                }
            }
        }.formStyle(.grouped).task {
            while !Task.isCancelled {
                model.refreshAccessibilityStatus()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}

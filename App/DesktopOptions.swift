import SwiftUI

struct DesktopToggles: View {
    @ObservedObject var model: DesktopModel
    let windowAction: (HotkeyAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach([HotkeyAction.left, .right, .topThird, .bottomTwoThirds, .maximize, .center], id: \.self) { action in
                    Button { windowAction(action) } label: {
                        WindowLayoutIcon(action: action).frame(maxWidth: .infinity).frame(height: 36)
                    }
                    .buttonStyle(LayoutTileStyle())
                    .help(Text("\(String(localized: action.title))（\(model.keyLabel(action))）"))
                    .accessibilityLabel(Text(action.title))
                    .accessibilityIdentifier("window-layout-\(action.rawValue)")
                }
            }
            HStack(spacing: 12) {
                Toggle("窗口边缘吸附", isOn: Binding(get: { model.snapping }, set: model.setSnapping))
                Toggle("隐藏刘海视觉", isOn: Binding(get: { model.notchEnabled }, set: model.setNotch))
                    .disabled(!model.notchAvailable)
                    .help(model.notchAvailable ? "切换刘海外观" : "当前没有可用的内置刘海屏")
            }.toggleStyle(.switch).controlSize(.mini)
        }.font(.callout)
    }
}

struct LayoutTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LayoutTile(configuration: configuration)
    }

    private struct LayoutTile: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var interaction = ControlInteraction()
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(interaction.active && enabled ? Color.accentColor : Color.primary)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(interaction.active && enabled ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: interaction.active)
                .onHover { interaction.active = $0 }
        }
    }
}

// Draw the occupied region directly so the two unequal vertical layouts are unambiguous.
struct WindowLayoutIcon: View {
    let action: HotkeyAction

    private var region: CGRect {
        switch action {
        case .left: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topThird: CGRect(x: 0, y: 0, width: 1, height: 1.0 / 3)
        case .bottomTwoThirds: CGRect(x: 0, y: 1.0 / 3, width: 1, height: 2.0 / 3)
        case .maximize: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .center: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        default: .zero
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 1.2)
            GeometryReader { geometry in
                let width = geometry.size.width - 6
                let height = geometry.size.height - 6
                let area = CGRect(x: 3 + region.minX * width, y: 3 + region.minY * height,
                                  width: region.width * width, height: region.height * height)
                Path(roundedRect: area, cornerRadius: 1).fill(.primary.opacity(0.8))
            }
        }.frame(width: 28, height: 22).accessibilityHidden(true)
    }
}

struct WindowSettings: View {
    @ObservedObject var model: DesktopModel

    var body: some View {
        Form {
            Section("窗口布局") {
                Toggle("拖动窗口到屏幕边缘时吸附", isOn: Binding(get: { model.snapping }, set: model.setSnapping))
                Stepper("窗口间距 \(Int(model.windowGap)) 点",
                        value: Binding(get: { model.windowGap }, set: model.setWindowGap), in: 0...32)
            }
            Section("辅助功能") {
                if model.accessibilityAuthorized {
                    Label("辅助功能已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("打开辅助功能授权") { model.windows.requestAccess() }
                    Text("此权限用于读取和调整窗口。若开关已打开，请重新打开 LuluDisplay 后检测。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("重新检测权限") { model.refreshAccessibilityStatus() }
            }
        }.formStyle(.grouped).task {
            while !Task.isCancelled {
                model.refreshAccessibilityStatus()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}

struct AppearanceSettings: View {
    @ObservedObject var model: DesktopModel

    var body: some View {
        Form {
            Section("菜单栏") {
                Toggle("隐藏刘海视觉", isOn: Binding(get: { model.notchEnabled }, set: model.setNotch))
                    .disabled(!model.notchAvailable)
                Text(model.notchAvailable ? "在内置屏幕菜单栏后方显示黑色衬底。" : "当前没有连接可用的内置刘海屏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var draft: AppSettings
    @State private var hotwordsText: String

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _draft = State(initialValue: coordinator.settings)
        _hotwordsText = State(initialValue: coordinator.settings.hotwordsText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                permissionSection
                hotkeySection
                insertionSection
                hotwordSection
                diagnosticsSection
            }
            .padding(24)
        }
        .frame(minWidth: 780, minHeight: 720)
        .onAppear {
            draft = coordinator.settings
            hotwordsText = coordinator.settings.hotwordsText
        }
    }

    private var permissionSection: some View {
        GroupBox("权限") {
            VStack(alignment: .leading, spacing: 12) {
                permissionRow(title: "麦克风", status: coordinator.permissions.microphone.displayTitle) {
                    coordinator.requestMicrophoneAccess()
                } requestDisabled: {
                    coordinator.runtime.isRequestingMicrophonePermission
                } settingsAction: {
                    coordinator.openSystemSettings(for: .microphone)
                }

                permissionRow(title: "辅助功能", status: coordinator.permissions.accessibility.displayTitle) {
                    coordinator.requestAccessibilityAccess()
                } settingsAction: {
                    coordinator.openSystemSettings(for: .accessibility)
                }

                permissionRow(title: "输入监控", status: coordinator.permissions.inputMonitoring.displayTitle, requestAction: nil) {
                    coordinator.openSystemSettings(for: .inputMonitoring)
                }
            }
        }
    }

    private var hotkeySection: some View {
        GroupBox("快捷键") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("按住式主热键", text: $draft.holdHotkey)
                TextField("单击切换修饰键", text: $draft.toggleModifierKey)
                Toggle("启动即预热模型", isOn: $draft.preloadModelOnLaunch)
                saveButton
            }
        }
    }

    private var insertionSection: some View {
        GroupBox("文本注入") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("注入方式", selection: $draft.pasteMode) {
                    ForEach(PasteMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("注入延迟")
                    Spacer()
                    TextField("毫秒", value: $draft.pasteDelayMs, formatter: NumberFormatter.integer)
                        .frame(width: 100)
                }

                Toggle("启用 ITN", isOn: $draft.useITN)
                saveButton
            }
        }
    }

    private var hotwordSection: some View {
        GroupBox("热词词表") {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $hotwordsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                saveButton
            }
        }
    }

    private var diagnosticsSection: some View {
        GroupBox("诊断日志") {
            VStack(alignment: .leading, spacing: 12) {
                Text("状态：\(coordinator.runtime.status.displayTitle)")
                Text("模型：\(modelStateText)")
                if let target = coordinator.runtime.pendingTargetAppName {
                    Text("目标应用：\(target)")
                }
                if !coordinator.runtime.lastTranscript.isEmpty {
                    Text("最近一次识别：\(coordinator.runtime.lastTranscript)")
                }
                ScrollView {
                    Text(coordinator.runtime.logs.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 220)
            }
        }
    }

    private var saveButton: some View {
        Button("保存设置") {
            var next = draft
            next.hotwords = hotwordsText
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            coordinator.applySettings(next)
        }
    }

    private var modelStateText: String {
        switch coordinator.runtime.status {
        case .warmingUp:
            return "装载中"
        case .unloading:
            return "卸载中"
        default:
            return coordinator.runtime.modelReady ? "已装载" : "未装载"
        }
    }

    private func permissionRow(title: String, status: String, requestAction: (() -> Void)?, requestDisabled: (() -> Bool)? = nil, settingsAction: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let requestAction {
                Button("请求权限", action: requestAction)
                    .disabled(requestDisabled?() ?? false)
            }
            Button("系统设置", action: settingsAction)
        }
    }
}

private extension NumberFormatter {
    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }()
}

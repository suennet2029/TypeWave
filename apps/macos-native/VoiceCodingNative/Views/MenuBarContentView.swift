import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if coordinator.runtime.isRecording || coordinator.runtime.isTranscribing || coordinator.runtime.pendingTranscriptionCount > 0 {
                activityCard
            } else {
                idleCard
            }

            if let error = coordinator.runtime.lastError {
                errorBanner(error)
            }

            controlSection

            footerHint
        }
        .padding(16)
        .frame(width: 312)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice Coding")
                    .font(.system(size: 20, weight: .semibold))

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 8, height: 8)

                    Text(coordinator.runtime.status.displayTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            StatusChip(
                title: modelBadgeTitle,
                tint: modelBadgeTint
            )
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: coordinator.runtime.isRecording ? "mic.fill" : "waveform.badge.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 34, height: 34)
                    .background(statusTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.runtime.isRecording ? "正在录音" : "正在识别")
                        .font(.system(size: 14, weight: .semibold))
                    Text(activitySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if coordinator.runtime.pendingTranscriptionCount > 0 {
                    Text("队列 \(coordinator.runtime.pendingTranscriptionCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }

            WaveformBarsView(samples: coordinator.runtime.waveformSamples, state: coordinator.runtime)
                .frame(height: 34)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var idleCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusTint)
                .frame(width: 38, height: 38)
                .background(statusTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(idleHeadline)
                    .font(.system(size: 14, weight: .semibold))
                Text(idleSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var controlSection: some View {
        VStack(spacing: 10) {
            Button(recordingButtonTitle) {
                coordinator.toggleRecording()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(coordinator.runtime.isRequestingMicrophonePermission)

            HStack(spacing: 10) {
                Button(modelButtonTitle) {
                    Task {
                        if coordinator.runtime.modelReady {
                            await coordinator.unloadModel()
                        } else {
                            await coordinator.warmupModel()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(coordinator.runtime.status == .warmingUp || coordinator.runtime.status == .unloading)

                Button("打开设置") {
                    coordinator.openSettingsWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }

            Button("退出") {
                coordinator.quit()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }

    private var footerHint: some View {
        Text("日志和最近一次识别结果放在设置页查看。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 0.84, green: 0.30, blue: 0.22))
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.98, green: 0.95, blue: 0.92))
        )
    }

    private var recordingButtonTitle: String {
        if coordinator.runtime.isRequestingMicrophonePermission {
            return "请求麦克风权限中"
        }
        return coordinator.runtime.isRecording ? "停止录音" : "开始录音"
    }

    private var modelButtonTitle: String {
        switch coordinator.runtime.status {
        case .warmingUp:
            return "装载中"
        case .unloading:
            return "卸载中"
        default:
            return coordinator.runtime.modelReady ? "卸载模型" : "装载模型"
        }
    }

    private var modelBadgeTitle: String {
        switch coordinator.runtime.status {
        case .warmingUp:
            return "装载中"
        case .unloading:
            return "卸载中"
        default:
            return coordinator.runtime.modelReady ? "模型就绪" : "按需装载"
        }
    }

    private var modelBadgeTint: Color {
        switch coordinator.runtime.status {
        case .warmingUp:
            return Color(red: 0.23, green: 0.49, blue: 0.96)
        case .unloading:
            return Color(red: 0.62, green: 0.48, blue: 0.14)
        default:
            return coordinator.runtime.modelReady
                ? Color(red: 0.15, green: 0.63, blue: 0.33)
                : .secondary
        }
    }

    private var statusTint: Color {
        switch coordinator.runtime.status {
        case .recording:
            return Color(red: 0.96, green: 0.40, blue: 0.28)
        case .transcribing:
            return Color(red: 0.41, green: 0.58, blue: 0.96)
        case .error:
            return Color(red: 0.84, green: 0.30, blue: 0.22)
        case .warmingUp:
            return Color(red: 0.23, green: 0.49, blue: 0.96)
        default:
            return Color(red: 0.17, green: 0.62, blue: 0.86)
        }
    }

    private var activitySubtitle: String {
        if let target = coordinator.runtime.pendingTargetAppName, !target.isEmpty {
            return target
        }
        return coordinator.runtime.isRecording ? "松开快捷键后开始最终识别" : "结果会自动写回当前输入框"
    }

    private var idleHeadline: String {
        if coordinator.runtime.modelReady {
            return "已经准备好"
        }
        if coordinator.runtime.status == .idle {
            return "等待权限或启动模型"
        }
        return "随时可以开始"
    }

    private var idleSubtitle: String {
        if coordinator.runtime.status == .idle {
            return "授予必要权限后，再按 \(formattedHotkey) 开始录音。"
        }
        if coordinator.runtime.modelReady {
            return "按 \(formattedHotkey) 开始录音，结束后会自动写回输入框。"
        }
        return "模型按需装载，首次识别会略慢一些。"
    }

    private var formattedHotkey: String {
        coordinator.settings.holdHotkey
            .replacingOccurrences(of: "option", with: "Option")
            .replacingOccurrences(of: "command", with: "Command")
            .replacingOccurrences(of: "shift", with: "Shift")
            .replacingOccurrences(of: "control", with: "Control")
    }
}

private struct StatusChip: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

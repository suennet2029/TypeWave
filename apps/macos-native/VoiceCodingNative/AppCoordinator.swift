import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var runtime = AppRuntimeState() {
        didSet {
            recordingHUDController.sync(runtime: runtime)
        }
    }
    @Published private(set) var permissions = PermissionState()
    @Published private(set) var settings: AppSettings

    private let paths: WorkspacePaths?
    private let settingsStore = SettingsStore()
    private let permissionCoordinator = PermissionCoordinator()
    private let audioCaptureService = AudioCaptureService()
    private let hotkeyMonitor = HotkeyMonitor()
    private let textInsertionService = TextInsertionService()
    private let helperProcess: HelperProcessManager
    private let recordingHUDController = RecordingHUDController()

    private var nativeLogs: [String] = []
    private var helperLogs: [String] = []
    private var currentRecordingTarget: TargetApp?
    private var queuedTranscriptions: [QueuedTranscription] = []
    private var activeTranscription: QueuedTranscription?
    private var lastSeenTranscriptRevision = 0
    private var idleUnloadTask: Task<Void, Never>?
    private var idleShutdownTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var shouldStartRecordingAfterMicrophonePermission = false
    private var settingsWindow: NSWindow?
    private var livePreviewTask: Task<Void, Never>?
    private var livePreviewInFlight = false
    private var pendingLivePreviewAudio: CapturedAudio?
    private var livePreviewSession: TextInsertionService.LiveInsertionSession?
    private var livePreviewRecordingSessionID = 0

    init() {
        let resolvedPaths = WorkspacePaths.resolve()
        self.paths = resolvedPaths
        self.settings = settingsStore.load(projectRoot: resolvedPaths?.workspaceRoot)
        self.helperProcess = HelperProcessManager(paths: resolvedPaths)

        configureCallbacks()
        appendNativeLog("原生菜单栏应用已初始化。")
        if let root = resolvedPaths?.workspaceRoot.path {
            appendNativeLog("运行目录：\(root)")
        } else {
            appendNativeLog("无法自动解析运行目录，helper 启动可能失败。")
        }
        recordingHUDController.sync(runtime: runtime)
    }

    func start() {
        registerForLifecycleNotifications()
        refreshPermissions()
        restartHotkeyMonitor()
        updateListeningStatusIfNeeded()
        if settings.preloadModelOnLaunch {
            Task { await warmupModel() }
        }
    }

    func applySettings(_ newSettings: AppSettings) {
        do {
            _ = try HotkeyMonitor.parseHoldHotkey(newSettings.holdHotkey)
        } catch {
            runtime.lastError = error.localizedDescription
            runtime.status = .error
            appendNativeLog("保存配置失败：\(error.localizedDescription)")
            return
        }

        settings = newSettings
        settingsStore.save(newSettings)
        appendNativeLog("设置已保存。")
        restartHotkeyMonitor()

        if newSettings.preloadModelOnLaunch && !runtime.modelReady {
            Task { await warmupModel() }
        } else {
            scheduleIdleLifecycleIfNeeded()
        }
    }

    func refreshPermissions() {
        permissions = permissionCoordinator.refresh()
    }

    func requestMicrophoneAccess() {
        Task {
            await requestMicrophonePermissionIfNeeded(startRecordingAfterGrant: false)
        }
    }

    func requestAccessibilityAccess() {
        permissions = permissionCoordinator.requestAccessibilityAccess()
        updateListeningStatusIfNeeded()
    }

    func openSystemSettings(for area: PermissionArea) {
        permissionCoordinator.openSystemSettings(for: area)
    }

    func openSettingsWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let hostingController = NSHostingController(rootView: SettingsView(coordinator: self))

            if let settingsWindow {
                settingsWindow.contentViewController = hostingController
                settingsWindow.orderFrontRegardless()
                settingsWindow.makeKey()
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Voice Coding 设置"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.setFrameAutosaveName("settings")
            window.center()
            window.contentViewController = hostingController
            window.orderFrontRegardless()
            window.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            self.settingsWindow = window
        }
    }

    func toggleRecording() {
        if runtime.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !runtime.isRecording else {
            return
        }

        guard !runtime.isRequestingMicrophonePermission else {
            shouldStartRecordingAfterMicrophonePermission = true
            appendNativeLog("麦克风权限请求仍在进行中，已忽略重复点击。")
            return
        }

        refreshPermissions()
        if permissions.microphone == .unknown {
            appendNativeLog("麦克风权限尚未确定，正在请求权限。")
            Task {
                await requestMicrophonePermissionIfNeeded(startRecordingAfterGrant: true)
            }
            return
        }

        guard permissions.microphone == .authorized else {
            runtime.lastError = "请先授予麦克风权限。"
            runtime.status = .error
            appendNativeLog("录音启动失败：缺少麦克风权限。")
            return
        }

        cancelIdleLifecycleTasks()

        currentRecordingTarget = TargetAppTracker.captureFrontmost()
        updatePendingTargetDisplay()
        primeWaveformForRecording()
        livePreviewRecordingSessionID &+= 1
        pendingLivePreviewAudio = nil
        livePreviewInFlight = false

        do {
            try audioCaptureService.start(maxDuration: TimeInterval(settings.maxAudioSeconds))
            runtime.isRecording = true
            runtime.recordingStartedAt = Date()
            runtime.status = .recording
            runtime.lastError = nil
            if activeTranscription == nil, queuedTranscriptions.isEmpty {
                livePreviewSession = textInsertionService.beginLiveInsertionSession()
                startLivePreviewLoop()
            } else {
                cancelLivePreviewIfNeeded()
            }
            appendNativeLog("开始录音。")
        } catch {
            runtime.lastError = error.localizedDescription
            runtime.status = .error
            livePreviewSession = nil
            appendNativeLog("录音启动失败：\(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard runtime.isRecording else {
            return
        }

        runtime.isRecording = false
        runtime.recordingStartedAt = nil
        runtime.currentLevel = 0
        stopLivePreviewLoop()

        let target = currentRecordingTarget
        currentRecordingTarget = nil
        let capturedAudio = audioCaptureService.stop()

        guard let capturedAudio else {
            cancelLivePreviewIfNeeded()
            updatePendingTargetDisplay()
            updateListeningStatusIfNeeded()
            appendNativeLog("录音结束，但没有采集到有效缓冲。")
            return
        }

        guard capturedAudio.duration >= settings.minAudioSeconds else {
            cancelLivePreviewIfNeeded()
            updatePendingTargetDisplay()
            updateListeningStatusIfNeeded()
            appendNativeLog("录音时间过短，已忽略。")
            scheduleIdleLifecycleIfNeeded()
            return
        }

        guard !capturedAudio.pcmData.isEmpty, !isSilent(data: capturedAudio.pcmData) else {
            cancelLivePreviewIfNeeded()
            updatePendingTargetDisplay()
            updateListeningStatusIfNeeded()
            appendNativeLog("录音几乎是静音，已忽略。")
            scheduleIdleLifecycleIfNeeded()
            return
        }

        appendNativeLog("录音结束，开始识别。")
        enqueueTranscription(capturedAudio, target: target)
    }

    func warmupModel() async {
        cancelIdleLifecycleTasks()
        do {
            try helperProcess.send(type: "warmup", payload: helperSettingsPayload())
            runtime.status = .warmingUp
            runtime.lastError = nil
            appendNativeLog("已请求装载识别模型。")
        } catch {
            runtime.lastError = error.localizedDescription
            runtime.status = .error
            appendNativeLog("模型装载失败：\(error.localizedDescription)")
        }
    }

    func unloadModel() async {
        do {
            try helperProcess.send(type: "unload_model")
            runtime.status = .unloading
            appendNativeLog("已请求卸载识别模型。")
        } catch {
            runtime.lastError = error.localizedDescription
            runtime.status = .error
            appendNativeLog("模型卸载失败：\(error.localizedDescription)")
        }
    }

    func quit() {
        helperProcess.shutdown()
        NSApplication.shared.terminate(nil)
    }

    private func configureCallbacks() {
        audioCaptureService.onMaxDurationReached = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendNativeLog("达到最长录音时长，自动结束录音。")
                self.stopRecording()
            }
        }
        audioCaptureService.onLevelUpdate = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.pushWaveformLevel(level)
            }
        }

        hotkeyMonitor.onHoldStart = { [weak self] in
            self?.startRecording()
        }
        hotkeyMonitor.onHoldEnd = { [weak self] in
            self?.stopRecording()
        }
        hotkeyMonitor.onToggleTap = { [weak self] in
            self?.toggleRecording()
        }

        helperProcess.onPacket = { [weak self] packet in
            self?.handleHelperPacket(packet)
        }
        helperProcess.onLogLine = { [weak self] line in
            self?.appendNativeLog(line)
        }
        helperProcess.onExit = { [weak self] status in
            guard let self else { return }
            self.runtime.modelReady = false
            self.runtime.isRecording = false
            self.runtime.recordingStartedAt = nil
            self.currentRecordingTarget = nil
            self.activeTranscription = nil
            self.stopLivePreviewLoop()
            self.cancelLivePreviewIfNeeded()
            self.refreshTranscriptionCounters()
            self.updatePendingTargetDisplay()
            self.updateListeningStatusIfNeeded()
            self.appendNativeLog("helper 已退出，exit code=\(status)")
            if !self.queuedTranscriptions.isEmpty {
                self.drainTranscriptionQueueIfNeeded()
            } else {
                self.scheduleIdleLifecycleIfNeeded()
            }
        }
    }

    private func registerForLifecycleNotifications() {
        guard notificationObservers.isEmpty else {
            return
        }

        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let previousPermissions = self.permissions
                    self.refreshPermissions()
                    if previousPermissions.inputMonitoring != self.permissions.inputMonitoring {
                        self.restartHotkeyMonitor()
                    } else {
                        self.updateListeningStatusIfNeeded()
                    }
                }
            }
        )
    }

    private func requestMicrophonePermissionIfNeeded(startRecordingAfterGrant: Bool) async {
        if runtime.isRequestingMicrophonePermission {
            shouldStartRecordingAfterMicrophonePermission = shouldStartRecordingAfterMicrophonePermission || startRecordingAfterGrant
            return
        }

        runtime.isRequestingMicrophonePermission = true
        shouldStartRecordingAfterMicrophonePermission = shouldStartRecordingAfterMicrophonePermission || startRecordingAfterGrant
        updateListeningStatusIfNeeded()

        permissions = await permissionCoordinator.requestMicrophoneAccess()
        runtime.isRequestingMicrophonePermission = false

        if permissions.microphone == .authorized {
            appendNativeLog("麦克风权限已授权。")
            runtime.lastError = nil
            updateListeningStatusIfNeeded()
            let shouldRetryRecording = shouldStartRecordingAfterMicrophonePermission
            shouldStartRecordingAfterMicrophonePermission = false
            if shouldRetryRecording {
                startRecording()
            }
            return
        }

        shouldStartRecordingAfterMicrophonePermission = false
        runtime.lastError = "请先授予麦克风权限。"
        runtime.status = .error
        appendNativeLog("麦克风权限请求后仍未授权。")
    }

    private func handleHelperPacket(_ packet: HelperPacket) {
        switch packet.type {
        case "ready", "state":
            handleHelperState(packet.payload)
        case "preview":
            handlePreviewPacket(packet.payload)
        case "error":
            let message = packet.payload["message"] as? String ?? "后台出现异常。"
            runtime.lastError = message
            runtime.status = .error
            appendNativeLog("[error] \(message)")
            cancelLivePreviewIfNeeded()
            if activeTranscription != nil {
                activeTranscription = nil
                refreshTranscriptionCounters()
                drainTranscriptionQueueIfNeeded()
            }
        case "ack":
            break
        default:
            appendNativeLog("收到未处理的 helper 事件：\(packet.type)")
        }
    }

    private func handleHelperState(_ payload: [String: Any]) {
        if let logs = payload["logs"] as? [String] {
            helperLogs = logs
            rebuildLogs()
        }

        runtime.modelReady = payload["modelReady"] as? Bool ?? runtime.modelReady
        if let transcript = payload["lastTranscript"] as? String {
            runtime.lastTranscript = transcript
        }
        if let transcriptRevision = payload["transcriptRevision"] as? Int {
            runtime.transcriptRevision = transcriptRevision
        }

        var helperMappedStatus: AppRuntimeStatus?
        if let status = payload["status"] as? String {
            helperMappedStatus = mapHelperStatus(status)
            applyHelperStatus(helperMappedStatus)
        }

        if runtime.transcriptRevision > lastSeenTranscriptRevision {
            lastSeenTranscriptRevision = runtime.transcriptRevision
            completeActiveTranscription(with: runtime.lastTranscript)
        } else if activeTranscription != nil,
                  let helperMappedStatus,
                  helperMappedStatus != .transcribing,
                  helperMappedStatus != .warmingUp
        {
            completeActiveTranscription(with: nil)
        }

        updatePendingTargetDisplay()
        updateListeningStatusIfNeeded()
        scheduleIdleLifecycleIfNeeded()
    }

    private func handlePreviewPacket(_ payload: [String: Any]) {
        let sessionID = payload["sessionId"] as? Int ?? 0
        guard sessionID == livePreviewRecordingSessionID else {
            return
        }

        livePreviewInFlight = false
        let previewText = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !previewText.isEmpty {
            applyLivePreview(previewText)
        }

        if runtime.isRecording, let pendingLivePreviewAudio {
            self.pendingLivePreviewAudio = nil
            sendLivePreview(pendingLivePreviewAudio)
        }
    }

    private func applyHelperStatus(_ helperMappedStatus: AppRuntimeStatus?) {
        guard let helperMappedStatus else {
            return
        }

        switch helperMappedStatus {
        case .requestingPermission:
            break
        case .warmingUp, .unloading:
            runtime.status = helperMappedStatus
        case .transcribing:
            runtime.isTranscribing = true
            if !runtime.isRecording {
                runtime.status = .transcribing
            }
        case .error:
            if !runtime.isRecording {
                runtime.status = .error
            }
        case .idle, .listening, .recording:
            break
        }
    }

    private func enqueueTranscription(_ capturedAudio: CapturedAudio, target: TargetApp?) {
        queuedTranscriptions.append(
            QueuedTranscription(
                audio: capturedAudio,
                target: target
            )
        )
        refreshTranscriptionCounters()
        updatePendingTargetDisplay()

        if runtime.pendingTranscriptionCount > 1 {
            appendNativeLog("已加入识别队列，当前排队 \(runtime.pendingTranscriptionCount) 段。")
        }

        drainTranscriptionQueueIfNeeded()
    }

    private func drainTranscriptionQueueIfNeeded() {
        guard activeTranscription == nil, !queuedTranscriptions.isEmpty else {
            refreshTranscriptionCounters()
            updatePendingTargetDisplay()
            return
        }

        let nextRequest = queuedTranscriptions.removeFirst()
        activeTranscription = nextRequest
        refreshTranscriptionCounters()
        updatePendingTargetDisplay()

        if !runtime.isRecording {
            runtime.status = .transcribing
        }

        Task { await transcribe(nextRequest) }
    }

    private func completeActiveTranscription(with text: String?) {
        let completedRequest = activeTranscription
        activeTranscription = nil
        refreshTranscriptionCounters()
        updatePendingTargetDisplay()

        if let text, !text.isEmpty {
            Task { await finalizeTranscription(text, target: completedRequest?.target) }
        } else {
            cancelLivePreviewIfNeeded()
        }

        drainTranscriptionQueueIfNeeded()
    }

    private func transcribe(_ request: QueuedTranscription) async {
        do {
            guard let paths else {
                throw NSError(domain: "VoiceCodingNative", code: 9, userInfo: [NSLocalizedDescriptionKey: "无法解析项目路径，不能调用 helper。"])
            }

            let audioURL = paths.tempDirectory.appendingPathComponent("voice-coding-\(UUID().uuidString).pcm")
            try request.audio.pcmData.write(to: audioURL, options: .atomic)
            try helperProcess.send(
                type: "transcribe_audio",
                payload: helperSettingsPayload().merging([
                    "audio_file_path": audioURL.path,
                    "sample_rate": settings.sampleRate,
                    "channels": settings.channels,
                    "duration_seconds": request.audio.duration,
                    "target_app_name": request.target?.localizedName ?? "",
                ]) { _, new in new }
            )
        } catch {
            runtime.lastError = error.localizedDescription
            runtime.status = .error
            cancelLivePreviewIfNeeded()
            appendNativeLog("识别请求失败：\(error.localizedDescription)")
            activeTranscription = nil
            refreshTranscriptionCounters()
            updatePendingTargetDisplay()
            drainTranscriptionQueueIfNeeded()
            updateListeningStatusIfNeeded()
            scheduleIdleLifecycleIfNeeded()
        }
    }

    private func finalizeTranscription(_ text: String, target: TargetApp?) async {
        if let livePreviewSession {
            if textInsertionService.commitLiveInsertion(text, session: livePreviewSession) {
                self.livePreviewSession = nil
                runtime.lastError = nil
                appendNativeLog("实时转写已完成。")
                updateListeningStatusIfNeeded()
                scheduleIdleLifecycleIfNeeded()
                return
            }

            textInsertionService.cancelLiveInsertion(livePreviewSession)
            self.livePreviewSession = nil
        }

        await injectTranscription(text, target: target)
    }

    private func injectTranscription(_ text: String, target: TargetApp?) async {
        do {
            try await textInsertionService.insertText(text, targetApp: target, settings: settings)
            runtime.lastError = nil
            appendNativeLog("结果已写入当前输入框。")
        } catch {
            runtime.lastError = error.localizedDescription
            runtime.status = .error
            appendNativeLog("文本注入失败：\(error.localizedDescription)")
        }
        updateListeningStatusIfNeeded()
        scheduleIdleLifecycleIfNeeded()
    }

    private func restartHotkeyMonitor() {
        hotkeyMonitor.stop()
        refreshPermissions()

        let requiresInputMonitoring = HotkeyMonitor.requiresInputMonitoring(for: settings)
        guard !requiresInputMonitoring || permissions.inputMonitoring == .authorized else {
            appendNativeLog("当前没有输入监控权限，全局热键不会生效。")
            updateListeningStatusIfNeeded()
            return
        }

        do {
            try hotkeyMonitor.start(settings: settings)
            appendNativeLog("全局热键已启用：\(settings.holdHotkey)，单击修饰键：\(settings.toggleModifierKey)")
            updateListeningStatusIfNeeded()
        } catch {
            runtime.lastError = error.localizedDescription
            runtime.status = .error
            appendNativeLog("全局热键启动失败：\(error.localizedDescription)")
        }
    }

    private func updateListeningStatusIfNeeded() {
        if runtime.isRequestingMicrophonePermission {
            runtime.status = .requestingPermission
            return
        }

        if runtime.isRecording {
            runtime.status = .recording
            return
        }

        if runtime.isTranscribing || runtime.pendingTranscriptionCount > 0 {
            runtime.status = .transcribing
            return
        }

        if runtime.status == .warmingUp || runtime.status == .unloading {
            return
        }

        let hotkeysAvailable = !HotkeyMonitor.requiresInputMonitoring(for: settings) || permissions.inputMonitoring == .authorized
        if hotkeysAvailable {
            runtime.status = .listening
        } else {
            runtime.status = .idle
        }
    }

    private func refreshTranscriptionCounters() {
        runtime.pendingTranscriptionCount = queuedTranscriptions.count + (activeTranscription == nil ? 0 : 1)
        runtime.isTranscribing = activeTranscription != nil || !queuedTranscriptions.isEmpty
    }

    private func updatePendingTargetDisplay() {
        if let currentRecordingTarget {
            runtime.pendingTargetAppName = currentRecordingTarget.localizedName
            return
        }

        if let activeTarget = activeTranscription?.target {
            runtime.pendingTargetAppName = activeTarget.localizedName
            return
        }

        if let nextTarget = queuedTranscriptions.first?.target {
            runtime.pendingTargetAppName = nextTarget.localizedName
            return
        }

        runtime.pendingTargetAppName = nil
    }

    private func primeWaveformForRecording() {
        if runtime.waveformSamples.isEmpty {
            runtime.waveformSamples = Array(repeating: 0.08, count: 20)
        }
        runtime.currentLevel = 0
        runtime.waveformSamples = runtime.waveformSamples.map { max(0.08, $0 * 0.72) }
    }

    private func pushWaveformLevel(_ level: Double) {
        let clippedLevel = min(max(level, 0), 1)
        runtime.currentLevel = clippedLevel
        if runtime.waveformSamples.isEmpty {
            runtime.waveformSamples = Array(repeating: 0.08, count: 20)
        }

        runtime.waveformSamples.removeFirst()
        runtime.waveformSamples.append(max(0.06, clippedLevel))
    }

    private func startLivePreviewLoop() {
        stopLivePreviewLoop()

        livePreviewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 850_000_000)
                self?.requestLivePreviewIfNeeded()
            }
        }
    }

    private func stopLivePreviewLoop() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
        pendingLivePreviewAudio = nil
        livePreviewInFlight = false
    }

    private func requestLivePreviewIfNeeded() {
        guard runtime.isRecording,
              activeTranscription == nil,
              queuedTranscriptions.isEmpty
        else {
            return
        }

        guard let snapshot = audioCaptureService.snapshot(),
              snapshot.duration >= max(settings.minAudioSeconds, 0.7),
              !snapshot.pcmData.isEmpty,
              !isSilent(data: snapshot.pcmData)
        else {
            return
        }

        if livePreviewInFlight {
            pendingLivePreviewAudio = snapshot
            return
        }

        sendLivePreview(snapshot)
    }

    private func sendLivePreview(_ audio: CapturedAudio) {
        guard let paths else {
            return
        }

        do {
            let audioURL = paths.tempDirectory.appendingPathComponent("voice-coding-preview-\(UUID().uuidString).pcm")
            try audio.pcmData.write(to: audioURL, options: .atomic)
            livePreviewInFlight = true
            try helperProcess.send(
                type: "preview_audio",
                payload: helperSettingsPayload().merging([
                    "audio_file_path": audioURL.path,
                    "sample_rate": settings.sampleRate,
                    "channels": settings.channels,
                    "duration_seconds": audio.duration,
                    "session_id": livePreviewRecordingSessionID,
                ]) { _, new in new }
            )
        } catch {
            livePreviewInFlight = false
            appendNativeLog("实时预览发送失败：\(error.localizedDescription)")
        }
    }

    private func applyLivePreview(_ text: String) {
        guard let livePreviewSession else {
            return
        }

        if !textInsertionService.updateLiveInsertion(text, session: livePreviewSession) {
            textInsertionService.cancelLiveInsertion(livePreviewSession)
            self.livePreviewSession = nil
        }
    }

    private func cancelLivePreviewIfNeeded() {
        guard let livePreviewSession else {
            return
        }
        textInsertionService.cancelLiveInsertion(livePreviewSession)
        self.livePreviewSession = nil
    }

    private func appendNativeLog(_ message: String) {
        let timestamp = DateFormatter.logTimestamp.string(from: Date())
        nativeLogs.append("[\(timestamp)] \(message)")
        nativeLogs = Array(nativeLogs.suffix(250))
        rebuildLogs()
    }

    private func rebuildLogs() {
        runtime.logs = Array((helperLogs + nativeLogs).suffix(500))
    }

    private func mapHelperStatus(_ helperStatus: String) -> AppRuntimeStatus {
        switch helperStatus {
        case "录音中":
            return .recording
        case "识别中":
            return .transcribing
        case "模型预热中":
            return .warmingUp
        case "卸载模型中":
            return .unloading
        case "监听中":
            return .listening
        case "待命", "已停止":
            return .idle
        default:
            return helperStatus.contains("失败") || helperStatus.contains("异常") ? .error : runtime.status
        }
    }

    private func scheduleIdleLifecycleIfNeeded() {
        cancelIdleLifecycleTasks()
        // Keep the helper/model resident until the user explicitly unloads it.
        // The previous idle lifecycle felt like the model was unloading on its own.
    }

    private func cancelIdleLifecycleTasks() {
        idleUnloadTask?.cancel()
        idleShutdownTask?.cancel()
        idleUnloadTask = nil
        idleShutdownTask = nil
    }

    private func isSilent(data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            return samples.allSatisfy { abs(Int($0)) < 4 }
        }
    }

    private func helperSettingsPayload() -> [String: Any] {
        [
            "language": settings.language,
            "use_itn": settings.useITN,
            "repo_id": settings.repoId,
            "model_dirname": settings.modelDirname,
            "sample_rate": settings.sampleRate,
            "channels": settings.channels,
            "min_audio_seconds": settings.minAudioSeconds,
            "max_audio_seconds": settings.maxAudioSeconds,
            "hotwords": settings.hotwords,
        ]
    }
}

private struct QueuedTranscription {
    let audio: CapturedAudio
    let target: TargetApp?
}

private extension DateFormatter {
    static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

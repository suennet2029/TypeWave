import Foundation

enum AppRuntimeStatus: String, Equatable {
    case idle
    case listening
    case requestingPermission
    case recording
    case transcribing
    case warmingUp
    case unloading
    case error

    var displayTitle: String {
        switch self {
        case .idle:
            return "待命"
        case .listening:
            return "监听中"
        case .requestingPermission:
            return "请求权限中"
        case .recording:
            return "录音中"
        case .transcribing:
            return "识别中"
        case .warmingUp:
            return "模型预热中"
        case .unloading:
            return "卸载模型中"
        case .error:
            return "异常"
        }
    }
}

struct AppRuntimeState: Equatable {
    var status: AppRuntimeStatus = .idle
    var isRecording = false
    var isTranscribing = false
    var modelReady = false
    var lastTranscript = ""
    var lastError: String?
    var pendingTargetAppName: String?
    var logs: [String] = []
    var transcriptRevision = 0
    var pendingTranscriptionCount = 0
    var currentLevel = 0.0
    var waveformSamples = Array(repeating: 0.08, count: 20)
    var recordingStartedAt: Date?
    var isRequestingMicrophonePermission = false
}

enum PermissionAuthorizationState: Equatable {
    case authorized
    case denied
    case unknown

    var displayTitle: String {
        switch self {
        case .authorized:
            return "已授权"
        case .denied:
            return "未授权"
        case .unknown:
            return "未知"
        }
    }
}

struct PermissionState: Equatable {
    var microphone: PermissionAuthorizationState = .unknown
    var accessibility: PermissionAuthorizationState = .unknown
    var inputMonitoring: PermissionAuthorizationState = .unknown
}

struct CapturedAudio {
    let pcmData: Data
    let duration: TimeInterval
}

struct TargetApp: Equatable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let localizedName: String
}

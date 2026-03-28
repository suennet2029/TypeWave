import Foundation

enum PasteMode: String, CaseIterable, Codable, Identifiable {
    case clipboard
    case type

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clipboard:
            return "剪贴板粘贴"
        case .type:
            return "逐字输入"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var holdHotkey: String
    var toggleModifierKey: String
    var pasteMode: PasteMode
    var pasteDelayMs: Int
    var language: String
    var useITN: Bool
    var repoId: String
    var modelDirname: String
    var sampleRate: Int
    var channels: Int
    var minAudioSeconds: Double
    var maxAudioSeconds: Int
    var preloadModelOnLaunch: Bool
    var hotwords: [String]

    static let `default` = AppSettings(
        holdHotkey: "option+r",
        toggleModifierKey: "",
        pasteMode: .clipboard,
        pasteDelayMs: 180,
        language: "auto",
        useITN: true,
        repoId: "FunAudioLLM/SenseVoiceSmall",
        modelDirname: "SenseVoiceSmall",
        sampleRate: 16_000,
        channels: 1,
        minAudioSeconds: 0.2,
        maxAudioSeconds: 90,
        preloadModelOnLaunch: false,
        hotwords: [
            "TypeScript",
            "JavaScript",
            "React",
            "useState",
            "useEffect",
            "useMemo",
            "useCallback",
            "useRef",
            "useContext",
            "useDebounce",
            "Next.js",
            "TailwindCSS",
            "Cursor",
            "Claude",
            "Ollama",
        ]
    )

    var hotwordsText: String {
        hotwords.joined(separator: "\n")
    }
}

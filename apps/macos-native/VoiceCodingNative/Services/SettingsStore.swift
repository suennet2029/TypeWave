import Foundation

final class SettingsStore {
    private let defaults: UserDefaults
    private let settingsKey = "VoiceCodingNative.settings.v1"
    private let importKey = "VoiceCodingNative.didImportLegacyConfig"
    private let shortcutMigrationKey = "VoiceCodingNative.didMigrateDefaultShortcut.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(projectRoot: URL?) -> AppSettings {
        if !defaults.bool(forKey: importKey), let projectRoot {
            if let migrated = migrateLegacySettings(from: projectRoot) {
                let normalized = normalize(migrated)
                save(normalized)
                defaults.set(true, forKey: importKey)
                return normalized
            }
            defaults.set(true, forKey: importKey)
        }

        guard let data = defaults.data(forKey: settingsKey) else {
            let normalizedDefault = normalize(.default)
            save(normalizedDefault)
            return normalizedDefault
        }

        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            let normalized = normalize(decoded)
            if normalized != decoded {
                save(normalized)
            }
            return normalized
        } catch {
            let normalizedDefault = normalize(.default)
            save(normalizedDefault)
            return normalizedDefault
        }
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: settingsKey)
    }

    private func migrateLegacySettings(from projectRoot: URL) -> AppSettings? {
        var migrated = AppSettings.default
        var didImportAnything = false

        let configURL = projectRoot.appendingPathComponent("config/app.yaml")
        if let rawConfig = try? String(contentsOf: configURL, encoding: .utf8) {
            for rawLine in rawConfig.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: ":") else {
                    continue
                }

                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                didImportAnything = true

                switch key {
                case "hotkey":
                    migrated.holdHotkey = value
                case "toggle_record_key":
                    migrated.toggleModifierKey = value
                case "paste_mode":
                    migrated.pasteMode = PasteMode(rawValue: value) ?? migrated.pasteMode
                case "paste_delay_ms":
                    migrated.pasteDelayMs = Int(value) ?? migrated.pasteDelayMs
                case "language":
                    migrated.language = value
                case "use_itn":
                    migrated.useITN = parseBool(value) ?? migrated.useITN
                case "repo_id":
                    migrated.repoId = value
                case "model_dirname":
                    migrated.modelDirname = value
                case "sample_rate":
                    migrated.sampleRate = Int(value) ?? migrated.sampleRate
                case "channels":
                    migrated.channels = Int(value) ?? migrated.channels
                case "min_audio_seconds":
                    migrated.minAudioSeconds = Double(value) ?? migrated.minAudioSeconds
                case "max_audio_seconds":
                    migrated.maxAudioSeconds = Int(value) ?? migrated.maxAudioSeconds
                case "auto_start_listening":
                    migrated.preloadModelOnLaunch = parseBool(value) ?? migrated.preloadModelOnLaunch
                default:
                    break
                }
            }
        }

        let hotwordsURL = projectRoot.appendingPathComponent("config/hotwords.txt")
        if let rawHotwords = try? String(contentsOf: hotwordsURL, encoding: .utf8) {
            let hotwords = rawHotwords
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !hotwords.isEmpty {
                migrated.hotwords = hotwords
                didImportAnything = true
            }
        }

        return didImportAnything ? migrated : nil
    }

    private func normalize(_ settings: AppSettings) -> AppSettings {
        var normalized = settings

        if !defaults.bool(forKey: shortcutMigrationKey), normalized.holdHotkey == "cmd+shift+space" {
            normalized.holdHotkey = "option+r"
        }
        if normalized.holdHotkey == "option+r", normalized.toggleModifierKey == "option" {
            normalized.toggleModifierKey = ""
        }

        defaults.set(true, forKey: shortcutMigrationKey)
        return normalized
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }
}

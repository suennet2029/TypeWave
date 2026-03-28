import Foundation

struct WorkspacePaths {
    let workspaceRoot: URL
    let pythonBinary: URL
    let desktopSourceRoot: URL
    let configDirectory: URL
    let modelsDirectory: URL
    let runtimeDirectory: URL
    let tempDirectory: URL
    let bundledModelsDirectory: URL?
    let isBundled: Bool

    static func resolve(bundle: Bundle = .main) -> WorkspacePaths? {
        let fileManager = FileManager.default
        if let bundled = resolveBundledPaths(bundle: bundle, fileManager: fileManager) {
            return bundled
        }

        let candidates = candidateWorkspaceRoots(bundle: bundle)

        for candidate in candidates {
            let root = candidate.standardizedFileURL
            if isWorkspaceRoot(root, fileManager: fileManager) {
                let runtimeDirectory = root.appendingPathComponent("runtime", isDirectory: true)
                let tempDirectory = runtimeDirectory.appendingPathComponent("tmp", isDirectory: true)
                try? fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
                try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                return WorkspacePaths(
                    workspaceRoot: root,
                    pythonBinary: root.appendingPathComponent(".venv/bin/python"),
                    desktopSourceRoot: root.appendingPathComponent("apps/desktop", isDirectory: true),
                    configDirectory: root.appendingPathComponent("config", isDirectory: true),
                    modelsDirectory: root.appendingPathComponent("models", isDirectory: true),
                    runtimeDirectory: runtimeDirectory,
                    tempDirectory: tempDirectory,
                    bundledModelsDirectory: nil,
                    isBundled: false
                )
            }
        }

        return nil
    }

    private static func resolveBundledPaths(bundle: Bundle, fileManager: FileManager) -> WorkspacePaths? {
        guard let resourceURL = bundle.resourceURL else {
            return nil
        }

        let backendRoot = resourceURL.appendingPathComponent("backend", isDirectory: true)
        let pythonBinary = backendRoot.appendingPathComponent("python/bin/python3.11")
        let sourceRoot = backendRoot.appendingPathComponent("src", isDirectory: true)

        guard
            fileManager.fileExists(atPath: pythonBinary.path),
            fileManager.fileExists(atPath: sourceRoot.path)
        else {
            return nil
        }

        let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Voice Coding", isDirectory: true)

        guard let appSupportRoot else {
            return nil
        }

        let configDirectory = appSupportRoot.appendingPathComponent("config", isDirectory: true)
        let modelsDirectory = appSupportRoot.appendingPathComponent("models", isDirectory: true)
        let runtimeDirectory = appSupportRoot.appendingPathComponent("runtime", isDirectory: true)
        let tempDirectory = runtimeDirectory.appendingPathComponent("tmp", isDirectory: true)
        let bundledModelsDirectory = backendRoot.appendingPathComponent("models", isDirectory: true)

        for directory in [appSupportRoot, configDirectory, modelsDirectory, runtimeDirectory, tempDirectory] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return WorkspacePaths(
            workspaceRoot: appSupportRoot,
            pythonBinary: pythonBinary,
            desktopSourceRoot: sourceRoot,
            configDirectory: configDirectory,
            modelsDirectory: modelsDirectory,
            runtimeDirectory: runtimeDirectory,
            tempDirectory: tempDirectory,
            bundledModelsDirectory: fileManager.fileExists(atPath: bundledModelsDirectory.path) ? bundledModelsDirectory : nil,
            isBundled: true
        )
    }

    private static func candidateWorkspaceRoots(bundle: Bundle) -> [URL] {
        var urls: [URL] = []

        if let override = ProcessInfo.processInfo.environment["VOICE_CODING_WORKSPACE_ROOT"], !override.isEmpty {
            appendAncestors(startingAt: URL(fileURLWithPath: override, isDirectory: true), levels: 2, into: &urls)
        }

        if
            let infoRoot = bundle.object(forInfoDictionaryKey: "VCWorkspaceRoot") as? String,
            let resolvedInfoRoot = parseConfiguredPath(infoRoot)
        {
            appendAncestors(startingAt: resolvedInfoRoot, levels: 2, into: &urls)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        appendAncestors(startingAt: cwd, levels: 8, into: &urls)

        if let bundleURL = bundle.bundleURL as URL? {
            appendAncestors(startingAt: bundleURL, levels: 8, into: &urls)
        }

        if let resourceURL = bundle.resourceURL {
            appendAncestors(startingAt: resourceURL, levels: 8, into: &urls)
        }

        return deduplicated(urls)
    }

    private static func isWorkspaceRoot(_ root: URL, fileManager: FileManager) -> Bool {
        let requiredPaths = [
            "apps/desktop/voice_coding_app",
            "apps/macos-native",
            "config",
        ]

        return requiredPaths.allSatisfy { relativePath in
            fileManager.fileExists(atPath: root.appendingPathComponent(relativePath).path)
        }
    }

    private static func parseConfiguredPath(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.contains("$(") || trimmed.contains("${") {
            return nil
        }

        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private static func appendAncestors(startingAt start: URL, levels: Int, into urls: inout [URL]) {
        var current = start.standardizedFileURL
        urls.append(current)

        for _ in 0..<levels {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                break
            }
            current = parent
            urls.append(current)
        }
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let key = url.standardizedFileURL.path
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }
}

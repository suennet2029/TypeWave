import Foundation

struct HelperPacket {
    let type: String
    let payload: [String: Any]
}

final class HelperProcessManager: @unchecked Sendable {
    var onPacket: ((HelperPacket) -> Void)?
    var onLogLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let paths: WorkspacePaths?
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()

    init(paths: WorkspacePaths?) {
        self.paths = paths
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func ensureStarted() throws {
        if isRunning {
            return
        }

        guard let paths else {
            throw NSError(
                domain: "VoiceCodingNative",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法定位运行目录。源码版请从仓库内构建运行，独立包请使用 Release 打包产物。"]
            )
        }

        let pythonBinary = paths.pythonBinary
        guard FileManager.default.fileExists(atPath: pythonBinary.path) else {
            throw NSError(domain: "VoiceCodingNative", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有找到 Python 虚拟环境：\(pythonBinary.path)"])
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.executableURL = pythonBinary
        process.arguments = ["-m", "voice_coding_app.helper_service"]
        process.currentDirectoryURL = paths.workspaceRoot
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONPATH"] = paths.desktopSourceRoot.path
        environment["VOICE_CODING_APP_HOME"] = paths.workspaceRoot.path
        if let bundledModelsDirectory = paths.bundledModelsDirectory {
            environment["VOICE_CODING_BUNDLED_MODELS_DIR"] = bundledModelsDirectory.path
        }
        let pythonLibraryDirectory = pythonBinary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lib", isDirectory: true)
        if FileManager.default.fileExists(atPath: pythonLibraryDirectory.path) {
            let existingLibraryPath = environment["DYLD_LIBRARY_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existingLibraryPath, !existingLibraryPath.isEmpty {
                environment["DYLD_LIBRARY_PATH"] = "\(pythonLibraryDirectory.path):\(existingLibraryPath)"
            } else {
                environment["DYLD_LIBRARY_PATH"] = pythonLibraryDirectory.path
            }
        }
        process.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeStdout(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let rawLine = String(data: data, encoding: .utf8) else { return }
            guard let sanitizedLine = Self.sanitizeLogLine(rawLine) else { return }
            DispatchQueue.main.async {
                self?.onLogLine?("[stderr] \(sanitizedLine)")
            }
        }

        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                self?.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self?.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self?.process = nil
                self?.stdoutPipe = nil
                self?.stderrPipe = nil
                self?.onExit?(task.terminationStatus)
            }
        }

        try process.run()

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.onLogLine?("后台 helper 已启动。")
    }

    func send(type: String, payload: [String: Any] = [:]) throws {
        try ensureStarted()
        guard let input = (process?.standardInput as? Pipe)?.fileHandleForWriting else {
            throw NSError(domain: "VoiceCodingNative", code: 3, userInfo: [NSLocalizedDescriptionKey: "helper stdin 不可用。"])
        }

        let body: [String: Any] = ["type": type, "payload": payload]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        input.write(data)
        input.write(Data([0x0A]))
    }

    func shutdown() {
        guard isRunning else {
            return
        }
        try? send(type: "shutdown")
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)

        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(...newline)

            guard !lineData.isEmpty else {
                continue
            }

            if let packet = parsePacket(from: Data(lineData)) {
                DispatchQueue.main.async { [weak self] in
                    self?.onPacket?(packet)
                }
            } else if let line = String(data: lineData, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in
                    self?.onLogLine?(line)
                }
            }
        }
    }

    private func parsePacket(from data: Data) -> HelperPacket? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return nil
        }

        return HelperPacket(type: type, payload: object["payload"] as? [String: Any] ?? [:])
    }

    private static func sanitizeLogLine(_ line: String) -> String? {
        let ansiPattern = #"\u{001B}\[[0-9;]*[A-Za-z]"#
        let withoutANSI = line.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )
        let sanitized = withoutANSI
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else {
            return nil
        }

        let suppressedFragments = [
            "rtf_avg:",
            "%|",
            "it/s",
        ]
        if suppressedFragments.contains(where: sanitized.contains) {
            return nil
        }

        return sanitized
    }
}

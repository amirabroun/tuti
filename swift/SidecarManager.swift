import Foundation

/// Runs `uv run server.py` in the tuti repo as a child process and restarts it if it crashes.
/// Its output appends to `Config.logURL` (`~/Library/Logs/tuti/server.log`).
@MainActor
final class SidecarManager {
    var onExit: ((String) -> Void)?

    private var process: Process?
    private var stopping = false

    func start() {
        guard process == nil else { return }
        stopping = false
        launch()
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    private func launch() {
        let p = Process()
        p.executableURL = Config.uvURL
        p.arguments = ["run", "--offline", "server.py", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        p.currentDirectoryURL = Config.repoURL
        // everything is cached locally; a dead network otherwise costs ~100 s of Hugging Face retries
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"  // tracebacks land in the log right away
        p.environment = env
        attachLog(to: p)
        let launchedAt = Date()
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.exited(status: status, after: Date().timeIntervalSince(launchedAt)) }
        }
        do {
            try p.run()
            process = p
        } catch {
            onExit?("Could not start the server: \(error.localizedDescription)")
        }
    }

    /// Appends the server's stdout/stderr to `Config.logURL`; a failure here only drops the log.
    /// shortcut: no rotation, a few lines per launch; add one if the file ever grows
    private func attachLog(to p: Process) {
        do {
            try FileManager.default.createDirectory(at: Config.logURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Config.logURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: Config.logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("--- \(Date()) launch\n".utf8))
            p.standardOutput = handle
            p.standardError = handle
        } catch {
            // no log: the server still starts
        }
    }

    /// Restart a crashed server, but not one we stopped and not one that dies while starting up:
    /// startup alone takes 4-6 s, so a startup failure (e.g. port 8765 taken) would just repeat.
    private func exited(status: Int32, after seconds: TimeInterval) {
        process = nil
        guard !stopping else { return }
        guard seconds > 60 else {
            onExit?("Server exited (code \(status)). Log: ~/Library/Logs/tuti/server.log. If the model or Python packages are missing, run `uv run server.py` in the tuti repo once.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.process == nil, !self.stopping else { return }
                self.launch()
            }
        }
    }
}

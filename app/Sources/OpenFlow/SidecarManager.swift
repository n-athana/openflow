import Foundation

/// Spawns `uv run server.py` from the asr/ directory and restarts it if it dies.
/// If something is already listening on the socket (e.g. a server started by hand), it is reused.
final class SidecarManager {
    let asrDir: String
    let socketPath: String
    let logPath = NSHomeDirectory() + "/Library/Logs/OpenFlow-asr.log"

    private var process: Process?
    private var stopping = false

    init(asrDir: String, socketPath: String) {
        self.asrDir = asrDir
        self.socketPath = socketPath
    }

    /// uv isn't on a GUI app's PATH.
    static let uv = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", NSHomeDirectory() + "/.local/bin/uv"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "uv"

    func start() {
        stopping = false
        guard process?.isRunning != true else { return }

        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.uv)
        p.arguments = ["run", "--project", asrDir, "python", "server.py", "--socket", socketPath,
                       "--vocabulary", Settings.useVocabulary ? Settings.vocabularyFile.path : ""]
        p.currentDirectoryURL = URL(fileURLWithPath: asrDir)
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = env["HF_HUB_OFFLINE"] ?? "1"  // model is cached; skip network checks
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, !self.stopping, self.process === proc else { return }
                NSLog("OpenFlow: ASR sidecar exited (%d), restarting", proc.terminationStatus)
                self.process = nil
                self.start()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("OpenFlow: failed to launch sidecar: %@", error.localizedDescription)
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
    }
}

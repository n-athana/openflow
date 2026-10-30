import Foundation

/// Learns the vocabulary from a vault by running asr/sweep.py: right after a vault is connected,
/// then whenever notes changed (checked at most every 30 min, and only while OpenFlow is idle).
/// The scan is paused (SIGSTOP) while you dictate or transcribe, so it never competes with live
/// recognition for the GPU, and it runs at background priority. The vault is only read.
final class VaultSweeper: ObservableObject {
    struct Vault: Hashable {
        let name: String
        let url: URL
    }

    enum Phase: Equatable {
        case idle
        case reading(done: Int, of: Int)
        case learning(done: Int, of: Int)
    }

    struct Result {
        let added: Int, removed: Int, total: Int
        let first: Bool  // the vault's first scan
        let requested: Bool  // you asked for it (connect, Rescan), rather than a background resync
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var running = false
    @Published private(set) var lastScan = Settings.lastVaultScan
    @Published private(set) var failed = false
    /// Dictating or transcribing: don't start a scan now.
    var isBusy: () -> Bool = { false }
    var onFinished: (Result) -> Void = { _ in }

    let logPath = NSHomeDirectory() + "/Library/Logs/OpenFlow-sweep.log"
    private let asrDir: String
    private var process: Process?
    private var paused = false
    private var buffer = Data()
    private var counts = (added: 0, removed: 0, total: 0)
    private var timer: Timer?
    private static let interval: TimeInterval = 30 * 60

    init(asrDir: String) {
        self.asrDir = asrDir
    }

    /// The vaults Obsidian knows, most recently opened first.
    static func knownVaults() -> [Vault] {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values
            .compactMap { v -> (Vault, Double)? in
                guard let path = v["path"] as? String, FileManager.default.fileExists(atPath: path) else { return nil }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                return (Vault(name: url.lastPathComponent, url: url), v["ts"] as? Double ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func name(of url: URL) -> String { url.lastPathComponent }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.maybeScan(force: false) }
        // Once at launch, after the ASR server had a head start on the GPU.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.maybeScan(force: true) }
    }

    func connect(_ url: URL) {
        cancel()
        Settings.vault = url
        Settings.lastVaultScan = nil
        lastScan = nil
        scan(requested: true)
    }

    /// Stops syncing; the terms learned so far stay in the file until you remove them.
    func disconnect() {
        cancel()
        Settings.vault = nil
    }

    /// `force`: skip the 30-minute spacing (launch), still only when something changed.
    private func maybeScan(force: Bool) {
        guard process == nil, let vault = Settings.vault, !isBusy() else { return }
        if let last = Settings.lastVaultScan {
            guard force || Date().timeIntervalSince(last) >= Self.interval, Self.changed(vault, since: last) else { return }
        }
        scan(requested: false)
    }

    /// Any note or folder modified since `date` (a deleted note bumps its folder).
    static func changed(_ vault: URL, since date: Date) -> Bool {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return false }
        if ((try? vault.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast) > date { return true }
        for case let url as URL in walk {
            if let m = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate, m > date { return true }
        }
        return false
    }

    /// `requested`: you're waiting for it, so it runs at normal priority. A background resync runs
    /// at background priority (slower, but you won't notice it).
    func scan(requested: Bool) {
        guard process == nil, let vault = Settings.vault else { return }
        let python = asrDir + "/.venv/bin/python"  // not `uv run`: its child wouldn't get SIGSTOP
        guard FileManager.default.isExecutableFile(atPath: python) else {
            NSLog("OpenFlow: no Python environment in %@ (run uv sync)", asrDir)
            failed = true
            return
        }
        let p = Process()
        let sweep = [python, "sweep.py", "--vault", vault.path, "--out", Settings.vocabularyFile.path]
        if requested {
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = Array(sweep.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")  // background priority; execs in place
            p.arguments = ["-b"] + sweep
        }
        p.currentDirectoryURL = URL(fileURLWithPath: asrDir)
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = env["HF_HUB_OFFLINE"] ?? "1"
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        FileManager.default.createFile(atPath: logPath, contents: nil)
        p.standardError = FileHandle(forWritingAtPath: logPath)
        let out = Pipe()
        p.standardOutput = out
        buffer = Data()
        counts = (0, 0, 0)
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        let first = Settings.lastVaultScan == nil
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.finished(proc, first: first, requested: requested) }
        }
        do {
            try p.run()
            process = p
            running = true
            phase = .reading(done: 0, of: 0)
            failed = false
        } catch {
            NSLog("OpenFlow: vault scan failed to start: %@", error.localizedDescription)
            failed = true
        }
        if isBusy() { pause() }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self)
            buffer.removeSubrange(...nl)
            let parts = line.split(separator: " ").map(String.init)
            switch parts.first {
            case "progress" where parts.count == 3:
                phase = .reading(done: Int(parts[1]) ?? 0, of: Int(parts[2]) ?? 0)
            case "llm" where parts.count == 3:
                phase = .learning(done: Int(parts[1]) ?? 0, of: Int(parts[2]) ?? 0)
            case "done":
                let fields = Dictionary(parts.dropFirst().compactMap { kv -> (String, String)? in
                    let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                    return p.count == 2 ? (p[0], p[1]) : nil
                }, uniquingKeysWith: { $1 })
                counts = (Int(fields["added"] ?? "") ?? 0, Int(fields["removed"] ?? "") ?? 0, Int(fields["total"] ?? "") ?? 0)
            default:
                break
            }
        }
    }

    private func finished(_ proc: Process, first: Bool, requested: Bool) {
        guard process === proc else { return }
        process = nil
        running = false
        paused = false
        phase = .idle
        if proc.terminationReason == .exit && proc.terminationStatus == 0 {
            Settings.lastVaultScan = Date()
            lastScan = Settings.lastVaultScan
            failed = false
            onFinished(Result(added: counts.added, removed: counts.removed, total: counts.total, first: first, requested: requested))
        } else if proc.terminationReason == .exit {
            NSLog("OpenFlow: vault scan exited with %d, see %@", proc.terminationStatus, logPath)
            failed = true
        }
    }

    /// While you dictate or transcribe. A paused scan keeps its memory and picks up where it was.
    func pause() {
        guard let p = process, !paused else { return }
        kill(p.processIdentifier, SIGSTOP)
        paused = true
    }

    func resume() {
        guard let p = process, paused else { return }
        kill(p.processIdentifier, SIGCONT)
        paused = false
    }

    func cancel() {
        guard let p = process else { return }
        resume()
        process = nil
        running = false
        p.terminate()
        phase = .idle
    }
}

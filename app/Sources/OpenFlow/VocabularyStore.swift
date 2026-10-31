import Foundation

/// The vocabulary file: names, acronyms and jargon the recognizer should get right. The format and
/// the Python parser are in asr/vocab.py; keep the two in step. Edits rewrite single lines, so
/// free text and anything else in the file stays as it was. The ASR server re-reads the file on
/// its own when it changes.
final class VocabularyStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        enum Source { case mine, vault }
        var id: String { text.lowercased() }
        let text: String
        let category: String
        let source: Source
        let aliases: [String]
        fileprivate let line: Int
    }

    static let categories = ["People", "Organizations", "Projects", "Products", "Acronyms", "Terms"]
    private static let start = "<!-- openflow:vault:start", end = "<!-- openflow:vault:end -->"
    private static let template = """
        # OpenFlow Vocabulary

        Domain:

        Words OpenFlow should recognize: names, acronyms, product and project words, one per line.
        Add what the recognizer writes instead as "(heard as: …)". Changes apply to the next dictation.

        ## Terms

        ## People

        ## Ignore

        """

    let url: URL
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var domain = ""
    @Published private(set) var ignored: [String] = []
    private var lines: [String] = []
    private var domainLine: Int?
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private static let reviewedKey = "vocabularyReviewed"

    init(url: URL = Settings.vocabularyFile, watch: Bool = true) {
        self.url = url
        reload()
        if watch { self.watch() }
    }

    // MARK: Reading

    func reload() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let parsed = Self.parse(lines)
        domain = parsed.domain ?? ""
        domainLine = parsed.domainLine
        entries = parsed.entries
        ignored = parsed.ignored
        pruneReviewed()
    }

    private static let heardAs = try! NSRegularExpression(pattern: #"\s*\(heard as:\s*(.*?)\)\s*$"#, options: .caseInsensitive)

    private static func parse(_ lines: [String]) -> (domain: String?, domainLine: Int?, entries: [Entry], ignored: [String]) {
        var domain: String?, domainLine: Int?
        var entries: [Entry] = [], ignored: [String] = []
        var seen = Set<String>(), ignoredKeys = Set<String>()
        var inBlock = false
        var category: String?
        for (i, raw) in lines.enumerated() {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix(start) { inBlock = true; category = nil; continue }
            if s.hasPrefix(end) { inBlock = false; category = nil; continue }
            if !inBlock, domainLine == nil, s.lowercased().hasPrefix("domain:") {
                domain = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                domainLine = i
                continue
            }
            if inBlock, s.hasPrefix("### ") { category = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces); continue }
            if s.hasPrefix("## ") { category = inBlock ? nil : String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
            if s.hasPrefix("#") { if !inBlock { category = nil }; continue }
            guard let cat = category, s.hasPrefix("- ") || s.hasPrefix("* ") else { continue }
            var text = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var aliases: [String] = []
            let ns = text as NSString
            if let m = heardAs.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                aliases = ns.substring(with: m.range(at: 1)).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                text = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            }
            guard !text.isEmpty else { continue }
            let key = text.lowercased()
            if !inBlock, cat.lowercased() == "ignore" {
                ignored.append(text)
                ignoredKeys.insert(key)
            } else if !seen.contains(key) {
                seen.insert(key)
                entries.append(Entry(text: text, category: cat, source: inBlock ? .vault : .mine, aliases: aliases, line: i))
            }
        }
        // Ignore only overrides the vault: a term you listed yourself stays.
        entries.removeAll { $0.source == .vault && ignoredKeys.contains($0.id) }
        return (domain, domainLine, entries, ignored)
    }

    // MARK: Review

    /// Vault terms you haven't looked at yet (tracked by the app, not in the file).
    var unreviewed: [Entry] {
        let reviewed = Self.reviewed
        return entries.filter { $0.source == .vault && !reviewed.contains($0.id) }
    }

    func isNew(_ entry: Entry) -> Bool { entry.source == .vault && !Self.reviewed.contains(entry.id) }

    /// Ends a review: `remove` go to Ignore, everything else from the review stays.
    func finishReview(of reviewed: [Entry], removing remove: Set<String>) {
        Self.reviewed.formUnion(reviewed.map(\.id))
        self.remove(reviewed.filter { remove.contains($0.id) })
        objectWillChange.send()
    }

    private static var reviewed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: reviewedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: reviewedKey) }
    }

    /// A term that left the file and comes back later counts as new again. Only for the real file:
    /// the selftest's and demos' temporary files would otherwise clear the list.
    private func pruneReviewed() {
        guard url.standardizedFileURL == Settings.vocabularyFile.standardizedFileURL else { return }
        let ids = Set(entries.map(\.id))
        let kept = Self.reviewed.intersection(ids)
        if kept.count != Self.reviewed.count { Self.reviewed = kept }
    }

    // MARK: Editing

    /// Adds one of your own terms, e.g. "Jana Weber" under People. Un-ignores it if it was ignored.
    func add(_ text: String, category: String = "Terms") {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !entries.contains(where: { $0.id == text.lowercased() && $0.source == .mine }) else { return }
        ensureFile()
        removeBullets(text, inSection: "Ignore")
        insertBullet(text, inSection: category)
        save()
    }

    /// Your own terms are deleted; vault terms go to Ignore, so the next scan doesn't bring them back.
    func remove(_ entry: Entry) { remove([entry]) }

    func remove(_ entries: [Entry]) {
        let valid = entries.filter { lines.indices.contains($0.line) }
        guard !valid.isEmpty else { return }
        for e in valid.sorted(by: { $0.line > $1.line }) { lines.remove(at: e.line) }  // bottom up: indices stay valid
        for e in valid where e.source == .vault { insertBullet(e.text, inSection: "Ignore") }
        save()
    }

    func setDomain(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != domain else { return }
        ensureFile()
        let line = text.isEmpty ? "Domain:" : "Domain: \(text)"
        if let i = domainLine, lines.indices.contains(i) {
            lines[i] = line
        } else {
            let title = lines.firstIndex { $0.hasPrefix("# ") }.map { $0 + 1 } ?? 0
            lines.insert(contentsOf: ["", line], at: title)
        }
        save()
    }

    func ensureFile() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.template.write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    /// Your sections end where the next heading or the vault block starts.
    private func manualSection(_ name: String) -> (header: Int, end: Int)? {
        var inBlock = false
        for (i, raw) in lines.enumerated() {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix(Self.start) { inBlock = true } else if s.hasPrefix(Self.end) { inBlock = false }
            guard !inBlock, s.hasPrefix("## "), s.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() else { continue }
            var end = i + 1
            while end < lines.count {
                let t = lines[end].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") || t.hasPrefix(Self.start) { break }
                end += 1
            }
            return (i, end)
        }
        return nil
    }

    private func insertBullet(_ text: String, inSection name: String) {
        if let (header, end) = manualSection(name) {
            // After the section's last bullet, before trailing blank lines.
            var at = end
            while at > header + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert("- \(text)", at: at)
            return
        }
        // A new section goes before Ignore (which stays last of yours), else before the vault block.
        let before = manualSection("Ignore").map(\.header) ?? lines.firstIndex { $0.hasPrefix(Self.start) }
        let block = ["## \(name)", "- \(text)", ""]
        if let before, name.lowercased() != "ignore" {
            lines.insert(contentsOf: block, at: before)
        } else if let start = lines.firstIndex(where: { $0.hasPrefix(Self.start) }) {
            lines.insert(contentsOf: block, at: start)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(contentsOf: block)
        }
    }

    private func removeBullets(_ text: String, inSection name: String) {
        guard let (header, end) = manualSection(name) else { return }
        for i in stride(from: end - 1, to: header, by: -1) {
            let s = lines[i].trimmingCharacters(in: .whitespaces)
            if (s.hasPrefix("- ") || s.hasPrefix("* ")), s.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased() == text.lowercased() {
                lines.remove(at: i)
            }
        }
    }

    private func save() {
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("OpenFlow: vocabulary save failed: %@", error.localizedDescription)
        }
        reload()
    }

    /// The sweep and your editor replace the file atomically, so the folder is what changes.
    private func watch() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reload() }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: Self-test

    /// Leaves its file at /tmp/openflow-vocab-selftest.md, so asr/vocab.py can be checked against it.
    static func selfTest() -> Bool {
        let url = URL(fileURLWithPath: "/tmp/openflow-vocab-selftest.md")
        let sample = template.replacingOccurrences(of: "## Terms\n", with: "## Terms\n- ACME\n- pull request (heard as: pool request)\n")
            + "\n\(start) x -->\n## From vault: Notes\n\n### People\n- Jana Weber\n- Lena\n\n### Products\n- Gemma\n\(end)\n"
        try? sample.write(to: url, atomically: true, encoding: .utf8)
        let store = VocabularyStore(url: url, watch: false)
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            if !cond { ok = false; print("FAIL vocabulary: \(what)") }
        }
        check(store.entries.map(\.text) == ["ACME", "pull request", "Jana Weber", "Lena", "Gemma"], "parse \(store.entries.map(\.text))")
        check(store.entries[1].aliases == ["pool request"], "aliases")
        store.remove(store.entries.first { $0.text == "Lena" }!)  // vault term: goes to Ignore
        check(store.ignored == ["Lena"] && !store.entries.contains { $0.text == "Lena" }, "remove vault term")
        store.add("Lena", category: "People")  // yours now: no longer ignored
        check(store.ignored.isEmpty && store.entries.contains { $0.text == "Lena" && $0.source == .mine }, "re-add")
        store.add("Data Garage", category: "Projects")  // new section
        check(store.entries.contains { $0.text == "Data Garage" && $0.category == "Projects" }, "new section")
        store.remove(store.entries.first { $0.text == "ACME" }!)
        check(!store.entries.contains { $0.text == "ACME" } && store.ignored.isEmpty, "remove own term")
        store.setDomain("logistics IT")
        check(store.domain == "logistics IT", "domain")
        let reread = VocabularyStore(url: url, watch: false)
        check(reread.entries.map(\.text) == store.entries.map(\.text), "round trip")
        print(ok ? "vocabulary ok" : "vocabulary FAILED")
        return ok
    }
}

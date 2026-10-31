import AppKit
import SwiftUI

/// What the Vocabulary page can ask the app to do.
struct VocabularyActions {
    var connect: (URL) -> Void
    var chooseFolder: () -> Void
    var disconnect: () -> Void
    var rescan: () -> Void
    var setUseVocabulary: (Bool) -> Void
}

/// The Vocabulary page of the OpenFlow window: the connected vault, what its scan learned, and
/// your own terms. New vault terms wait for a review.
struct VocabularyPage: View {
    @ObservedObject var store: VocabularyStore
    @ObservedObject var sweeper: VaultSweeper
    var actions: VocabularyActions
    @State private var query = ""
    @State private var domain = ""
    @State private var reviewing = false
    @State private var useVocabulary = Settings.useVocabulary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Vocabulary", subtitle: AppModel.Page.vocabulary.subtitle)
                .padding(.bottom, 8)
            VaultCard(sweeper: sweeper, actions: actions)
            if !store.unreviewed.isEmpty && !sweeper.running {
                reviewBanner
            }
            domainRow
            searchRow
            list
            footer
        }
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 36)
        .padding(.top, 50)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { domain = store.domain }
        .onChange(of: store.domain) { domain = store.domain }
        .sheet(isPresented: $reviewing) {
            ReviewSheet(store: store, entries: store.unreviewed) { reviewing = false }
        }
    }

    private var reviewBanner: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "sparkles", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(store.unreviewed.count) new terms from your vault").font(.system(size: 13, weight: .semibold))
                Text("OpenFlow already listens for them. A quick look keeps the list clean.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review…") { reviewing = true }
                .buttonStyle(.primary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.ember.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.ember.opacity(0.25)))
    }

    private var domainRow: some View {
        HStack(spacing: 8) {
            TextField("Your field, e.g. logistics IT and data analytics", text: $domain)
                .textFieldStyle(WellFieldStyle(icon: "briefcase"))
                .onSubmit { store.setDomain(domain) }
        }
        .help("What you work on. Helps the transcript cleanup pick the right words. Press Return to save.")
    }

    // MARK: Search and add

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var exactMatch: Bool { store.entries.contains { $0.id == trimmedQuery.lowercased() } }

    private var searchRow: some View {
        HStack(spacing: 8) {
            TextField("Search, or type a new term and press Return", text: $query)
                .textFieldStyle(WellFieldStyle(icon: "magnifyingglass"))
                .onSubmit { if !trimmedQuery.isEmpty && !exactMatch { add("Terms") } }
            Menu {
                ForEach(VocabularyStore.categories, id: \.self) { c in Button("Add to \(c)") { add(c) } }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: { add("Terms") }
                .menuStyle(.button)
                .buttonStyle(.quiet)
                .fixedSize()
                .disabled(trimmedQuery.isEmpty || exactMatch)
                .help("Adds to Terms; the arrow picks a category")
        }
    }

    private func add(_ category: String) {
        store.add(trimmedQuery, category: category)
        query = ""
    }

    // MARK: List

    private var someReviewed: Bool { store.unreviewed.count < store.entries.filter { $0.source == .vault }.count }

    private var filtered: [VocabularyStore.Entry] {
        let q = trimmedQuery.lowercased()
        return store.entries.filter { e in q.isEmpty || e.id.contains(q) || e.aliases.contains { $0.lowercased().contains(q) } }
    }

    @ViewBuilder private var list: some View {
        if store.entries.isEmpty {
            ContentUnavailableView("No terms yet", systemImage: "character.book.closed",
                                   description: Text("Connect a vault above, or type a name and press Return."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView("Nothing matches", systemImage: "magnifyingglass",
                                   description: Text("Press Return to add “\(trimmedQuery)”."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(TermGroup.groups(filtered), id: \.name) { group in
                    Section("\(group.name) · \(group.entries.count)") {
                        // Dots only mean something once part of the list is reviewed; the banner covers "all new".
                        ForEach(group.entries) { EntryRow(entry: $0, isNew: someReviewed && store.isNew($0)) { store.remove($0) } }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline))
            .frame(minHeight: 140, maxHeight: .infinity)  // scroll in the space left; never size the window
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Use vocabulary", isOn: $useVocabulary)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: useVocabulary) { actions.setUseVocabulary(useVocabulary) }
                .help("Off: OpenFlow transcribes as if the list were empty (restarts the recognizer)")
            Spacer()
            Text("\(store.entries.count) terms").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Open as Markdown") {
                store.ensureFile()
                NSWorkspace.shared.open(store.url)
            }
            .buttonStyle(.quietSmall)
        }
    }
}

struct TermGroup {
    let name: String
    let entries: [VocabularyStore.Entry]

    static func groups(_ entries: [VocabularyStore.Entry]) -> [TermGroup] {
        let byCategory = Dictionary(grouping: entries, by: \.category)
        let order = VocabularyStore.categories + byCategory.keys.filter { !VocabularyStore.categories.contains($0) }.sorted()
        return order.compactMap { c in byCategory[c].map { TermGroup(name: c, entries: $0) } }
    }
}

/// The connected vault and its sync state, or the invitation to connect one.
private struct VaultCard: View {
    @ObservedObject var sweeper: VaultSweeper
    var actions: VocabularyActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let vault = Settings.vault {
                HStack(spacing: 10) {
                    IconBadge(symbol: "books.vertical.fill", size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(VaultSweeper.name(of: vault)).font(.system(size: 14, weight: .semibold))
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(status).font(.system(size: 11.5))
                                .foregroundStyle(sweeper.failed ? AnyShapeStyle(Brand.emberText) : AnyShapeStyle(.secondary))
                        }
                    }
                    Spacer()
                    Button { actions.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .buttonStyle(.quietSmall)
                        .disabled(sweeper.running)
                    vaultMenu
                }
                if sweeper.running {
                    progress
                }
            } else {
                HStack(spacing: 10) {
                    IconBadge(symbol: "books.vertical", size: 34, tint: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn from your notes").font(.system(size: 14, weight: .semibold))
                        Text("Connect an Obsidian vault: OpenFlow picks up names, acronyms and project words, "
                            + "and keeps them up to date. Your vault is only read; nothing leaves your Mac.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    vaultMenu
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline))
    }

    @ViewBuilder private var progress: some View {
        switch sweeper.phase {
        case .reading(let done, let total) where total > 0, .learning(let done, let total) where total > 0:
            ProgressView(value: Double(done), total: Double(total)) {
                Text("Learning from notes… \(done) of \(total)").font(.system(size: 11))
            }
        default:
            ProgressView { Text("Starting…").font(.system(size: 11)) }.progressViewStyle(.linear)
        }
    }

    private var status: String {
        if sweeper.running { return "Scanning…" }
        if sweeper.failed { return "The last scan failed. See ~/Library/Logs/OpenFlow-sweep.log" }
        guard let last = sweeper.lastScan else { return "Not scanned yet" }
        return "Up to date · synced " + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: .now)
            + " · rescans on its own when notes change"
    }

    private var vaultMenu: some View {
        Menu {
            let known = VaultSweeper.knownVaults()
            if !known.isEmpty {
                Section("Obsidian vaults") {
                    ForEach(known, id: \.self) { v in
                        Toggle(v.name, isOn: Binding(get: { Settings.vault == v.url }, set: { _ in actions.connect(v.url) }))
                    }
                }
            }
            Button("Choose Folder…", action: actions.chooseFolder)
            if Settings.vault != nil {
                Divider()
                Button("Disconnect", role: .destructive, action: actions.disconnect)
            }
        } label: {
            if Settings.vault == nil { Text("Connect Vault") } else { Image(systemName: "ellipsis") }
        }
        .menuStyle(.button)
        .buttonStyle(Settings.vault == nil ? AnyButtonStyle(.primary) : AnyButtonStyle(.quietSmall))
        .menuIndicator(Settings.vault == nil ? .visible : .hidden)
        .fixedSize()
    }
}

private struct EntryRow: View {
    let entry: VocabularyStore.Entry
    let isNew: Bool
    var onRemove: (VocabularyStore.Entry) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if isNew {
                Circle().fill(Brand.ember).frame(width: 6, height: 6).help("Not reviewed yet")
            }
            Text(entry.text).font(.system(size: 13))
            if !entry.aliases.isEmpty {
                Text("heard as " + entry.aliases.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(entry.source == .mine ? "yours" : "vault")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(entry.source == .mine ? AnyShapeStyle(Brand.emberText) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(entry.source == .mine ? AnyShapeStyle(Brand.ember.opacity(0.12)) : AnyShapeStyle(Brand.well)))
            Button { onRemove(entry) } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help(entry.source == .mine ? "Remove" : "Remove: the vault scan won't add it again")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// New vault terms, all ticked: untick what doesn't belong, then Done. Unticked terms go to Ignore.
private struct ReviewSheet: View {
    @ObservedObject var store: VocabularyStore
    let entries: [VocabularyStore.Entry]
    var onDone: () -> Void
    @State private var removing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review \(entries.count) new terms").font(.display(20))
                Text("Untick anything that isn't a name, product or term you use. Unticked terms go to Ignore, "
                    + "so the next scan won't bring them back.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach(TermGroup.groups(entries), id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.entries) { e in
                            Toggle(isOn: Binding(
                                get: { !removing.contains(e.id) },
                                set: { keep in if keep { removing.remove(e.id) } else { removing.insert(e.id) } }
                            )) {
                                Text(e.text).font(.system(size: 13))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.hairline))
            .frame(minHeight: 320)
            HStack {
                Text(removing.isEmpty ? "Keeping all" : "Removing \(removing.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Later", action: onDone).keyboardShortcut(.cancelAction).buttonStyle(.quiet)
                Button("Done") {
                    store.finishReview(of: entries, removing: removing)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primary)
            }
        }
        .padding(22)
        .frame(width: 460, height: 580)
        .background(Brand.canvas)
        .tint(Brand.ember)
    }
}

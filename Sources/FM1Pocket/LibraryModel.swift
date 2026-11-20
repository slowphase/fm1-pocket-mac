import Foundation
import PocketKit

/// One firmware the library shows: the built-in h1 or a catalogue entry.
struct LibraryItem: Identifiable, Hashable {
    enum Source: Hashable {
        case builtin(URL)
        case catalogue(CatalogueEntry)
    }

    enum Download: Hashable {
        case installed
        /// an older build is on disk (its version); the current one is not yet
        case olderInstalled(String)
        case notDownloaded
    }

    let source: Source
    let id: String
    let name: String
    let version: String
    let authors: String
    let category: String
    let tag: String
    let about: String
    let license: String
    let sourceURL: String?
    let imageURL: URL?
    let screenshotFile: URL?
    let size: Int
    let download: Download
    let downloading: Bool
    let lastError: String?
    var isNew = false
    var isBeta = false
    /// no longer in Pocket's catalogue (kept because it was downloaded)
    var isWithdrawn = false
    var added: String?
    var updated: String?
    var previousVersion: String?

    var isBuiltin: Bool { if case .builtin = source { return true } else { return false } }

    static func builtinH1(screenshot: URL? = nil) -> LibraryItem? {
        guard let url = Bundle.main.url(forResource: "h1", withExtension: "rfm1"),
              let data = try? Data(contentsOf: url), let f = try? RFM1File(data) else { return nil }
        return LibraryItem(source: .builtin(url), id: "builtin:" + f.id, name: f.name, version: f.version,
                           authors: f.authors.joined(separator: ", "), category: "Built in", tag: "Built into this app",
                           about: "Jake Handy's h1, built into the app so there is always something to play, even offline.",
                           license: f.license, sourceURL: f.sourceURL, imageURL: nil, screenshotFile: screenshot, size: data.count,
                           download: .installed, downloading: false, lastError: nil)
    }

    init(source: Source, id: String, name: String, version: String, authors: String, category: String, tag: String,
         about: String, license: String, sourceURL: String?, imageURL: URL?, screenshotFile: URL?, size: Int,
         download: Download, downloading: Bool, lastError: String?) {
        self.source = source; self.id = id; self.name = name; self.version = version; self.authors = authors
        self.category = category; self.tag = tag; self.about = about; self.license = license
        self.sourceURL = sourceURL; self.imageURL = imageURL; self.screenshotFile = screenshotFile; self.size = size
        self.download = download; self.downloading = downloading; self.lastError = lastError
    }

    init(_ s: FirmwareLibrary.Entry, base: URL) {
        let e = s.entry
        var src = e.source
        if let u = src, let c = e.commit { src = u + "/tree/" + c }
        let dl: Download
        switch s.availability {
        case .installed: dl = .installed
        case .olderInstalled: dl = .olderInstalled(s.current?.version ?? "")
        case .notDownloaded: dl = .notDownloaded
        }
        self.init(source: .catalogue(e), id: "cat:" + e.id, name: e.name, version: e.version, authors: e.authorLine,
                  category: e.category, tag: e.tag, about: e.about, license: e.license, sourceURL: src,
                  imageURL: e.image.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }, screenshotFile: s.screenshotFile,
                  size: e.size, download: dl, downloading: s.downloading, lastError: s.lastError)
        isBeta = e.beta
        added = e.added
        updated = e.updated
        if let p = s.previous, p.sha256 != e.sha256 { previousVersion = p.version }
    }

    /// a firmware Pocket no longer lists, from what the library kept about it
    init?(withdrawn r: FirmwareRecord, paths: LibraryPaths) {
        guard let e = r.entry, let cur = r.current else { return nil }
        let shot = cur.screenshot.map { paths.screenshotFile($0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        self.init(source: .catalogue(e), id: "cat:" + e.id, name: e.name, version: cur.version, authors: e.authorLine,
                  category: e.category, tag: e.tag, about: e.about, license: e.license, sourceURL: e.source,
                  imageURL: nil, screenshotFile: shot, size: cur.size, download: .installed, downloading: false, lastError: nil)
        isWithdrawn = true
        added = e.added
        updated = e.updated
        previousVersion = r.previous?.version
    }

    /// a short download state, for the list view's Status column
    var statusText: String {
        if downloading { return "Downloading" }
        switch download {
        case .installed: return isBuiltin ? "Built in" : "Downloaded"
        case .olderInstalled: return "Update pending"
        case .notDownloaded: return lastError == nil ? "Not downloaded" : "Failed"
        }
    }

    var byline: String { [version, authors].filter { !$0.isEmpty }.joined(separator: " · ") }
    var searchFields: [String] { [name, version, authors, about, tag, category] }

    var downloadText: String {
        if downloading { return "Downloading…" }
        if isWithdrawn { return "Downloaded (no longer in the Pocket catalogue)" }
        switch download {
        case .installed: return isBuiltin ? "Built in" : "Downloaded"
        case .olderInstalled(let v): return "Version \(v) downloaded; the update is not downloaded yet"
        case .notDownloaded: return lastError == nil ? "Not downloaded yet" : "Download failed: \(lastError!)"
        }
    }
}

/// What the player needs to run a firmware.
struct PlayableFirmware {
    var data: Data
    var sha256: String
    /// the catalogue id, for catalogue firmware
    var catalogueID: String?
    /// true when an older installed build is played because the current one could not be had
    var isFallback: Bool
    var version: String
}

/// The library window's sections.
enum SidebarItem: Hashable {
    case all, favourites, recent, new, withdrawn
    case category(String)

    var key: String {
        switch self {
        case .all: return "all"
        case .favourites: return "favourites"
        case .recent: return "recent"
        case .new: return "new"
        case .withdrawn: return "withdrawn"
        case .category(let c): return "category:" + c
        }
    }
    init(key: String) {
        switch key {
        case "favourites": self = .favourites
        case "recent": self = .recent
        case "new": self = .new
        case "withdrawn": self = .withdrawn
        default: self = key.hasPrefix("category:") ? .category(String(key.dropFirst(9))) : .all
        }
    }
    var title: String {
        switch self {
        case .all: return "All Firmware"
        case .favourites: return "Favourites"
        case .recent: return "Recently Played"
        case .new: return "New"
        case .withdrawn: return "No Longer Listed"
        case .category(let c): return c
        }
    }
}

enum ViewMode: String, CaseIterable { case icons, list }

enum SortKey: String, CaseIterable, Identifiable {
    case name, author, category, added
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .author: return "Author"
        case .category: return "Category"
        case .added: return "Date Added"
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var withdrawnItems: [LibraryItem] = []
    @Published private(set) var status = ""
    @Published private(set) var isRefreshing = false
    @Published var selection: LibraryItem.ID?
    @Published var search = ""
    @Published var section: SidebarItem = .all { didSet { defaults.set(section.key, forKey: "library.section") } }
    @Published var viewMode: ViewMode = .icons { didSet { defaults.set(viewMode.rawValue, forKey: "library.viewMode") } }
    @Published var sort: SortKey = .name { didSet { defaults.set(sort.rawValue, forKey: "library.sort") } }
    @Published private(set) var favourites: Set<String> = []
    @Published private(set) var recent: [String: Date] = [:]

    /// the firmware store: catalogue, downloads, cache, cleanup (PocketKit/FirmwareLibrary.swift)
    let library = FirmwareLibrary()
    private let defaults = UserDefaults.standard
    private lazy var favouritesStore = FavouritesStore(paths: library.paths)
    private lazy var recentStore = RecentStore(paths: library.paths)
    private var started = false
    private var reloadPending = false
    private var lastSync = ""
    private var builtinShot: URL?

    init() {
        section = SidebarItem(key: defaults.string(forKey: "library.section") ?? "all")
        viewMode = ViewMode(rawValue: defaults.string(forKey: "library.viewMode") ?? "") ?? .icons
        sort = SortKey(rawValue: defaults.string(forKey: "library.sort") ?? "") ?? .name
        selection = defaults.string(forKey: "library.selection")
    }

    // MARK: what the browser shows

    /// the current section, searched and sorted
    var visible: [LibraryItem] {
        var list: [LibraryItem]
        switch section {
        case .all: list = items
        case .favourites: list = (items + withdrawnItems).filter { favourites.contains($0.id) }
        case .recent: list = (items + withdrawnItems).filter { recent[$0.id] != nil }
        case .new: list = items.filter(\.isNew)
        case .withdrawn: list = withdrawnItems
        case .category(let c): list = items.filter { $0.category == c }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { LibrarySearch.matches(q, fields: $0.searchFields) } }
        if section == .recent && q.isEmpty {
            return list.sorted { (recent[$0.id] ?? .distantPast) > (recent[$1.id] ?? .distantPast) }
        }
        return list.sorted { a, b in
            if a.isBuiltin != b.isBuiltin { return a.isBuiltin }
            if !q.isEmpty {
                let ra = LibrarySearch.rank(name: a.name, query: q), rb = LibrarySearch.rank(name: b.name, query: q)
                if ra != rb { return ra < rb }
            }
            switch sort {
            case .name: break
            case .author:
                let c = a.authors.localizedCaseInsensitiveCompare(b.authors)
                if c != .orderedSame { return c == .orderedAscending }
            case .category:
                let c = a.category.localizedCaseInsensitiveCompare(b.category)
                if c != .orderedSame { return c == .orderedAscending }
            case .added:
                let x = a.added ?? "", y = b.added ?? ""
                if x != y { return x > y }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// the catalogue's categories, alphabetically
    var categoryNames: [String] {
        Array(Set(items.filter { !$0.isBuiltin }.map(\.category))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func count(_ s: SidebarItem) -> Int {
        switch s {
        case .all: return items.count
        case .favourites: return (items + withdrawnItems).filter { favourites.contains($0.id) }.count
        case .recent: return (items + withdrawnItems).filter { recent[$0.id] != nil }.count
        case .new: return items.filter(\.isNew).count
        case .withdrawn: return withdrawnItems.count
        case .category(let c): return items.filter { $0.category == c }.count
        }
    }

    func select(_ id: LibraryItem.ID?) {
        selection = id
        defaults.set(id, forKey: "library.selection")
    }

    // MARK: favourites and recents (user-owned, in UserData/)

    func isFavourite(_ item: LibraryItem) -> Bool { favourites.contains(item.id) }

    func toggleFavourite(_ item: LibraryItem) {
        if favourites.contains(item.id) { favourites.remove(item.id) } else { favourites.insert(item.id) }
        try? favouritesStore.save(favourites)
    }

    func notePlayed(_ item: LibraryItem) {
        if let r = try? recentStore.note(item.id) { recent = r }
    }

    /// downloads a firmware now, ahead of background downloads
    func download(_ item: LibraryItem) {
        guard case .catalogue(let e) = item.source else { return }
        let lib = library
        Task { _ = try? await lib.ensureInstalled(e, priority: .interactive) }
    }

    func item(_ id: LibraryItem.ID?) -> LibraryItem? { (items + withdrawnItems).first { $0.id == id } }

    /// Shows the cached library at once, then synchronises in the background.
    func start() {
        guard !started else { return }
        started = true
        favourites = favouritesStore.load()
        recent = recentStore.load()
        let lib = library
        // h1 is built in, so the catalogue has no picture of it: make one the way Pocket makes its own
        if let h1 = Bundle.main.url(forResource: "h1", withExtension: "rfm1") {
            let paths = lib.paths
            Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: h1), let shot = ScreenshotMaker.cachedScreenshot(for: data, paths: paths) else { return }
                await MainActor.run {
                    self.builtinShot = shot
                    self.scheduleReload()
                }
            }
        }
        Task {
            await lib.setOnChange { [weak self] in
                Task { @MainActor in self?.scheduleReload() }
            }
            await reload()
            refresh()
        }
    }

    /// Check for Firmware Updates: fetch the catalogue, download what is new or missing, clean up.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        status = "Checking for firmware updates…"
        Task {
            let r = await library.sync()
            isRefreshing = false
            if let err = r.catalogueError {
                lastSync = "Offline: showing the downloaded library. (\(err))"
            } else {
                var parts: [String] = []
                if !r.installed.isEmpty { parts.append("\(r.installed.count) downloaded") }
                if !r.failed.isEmpty { parts.append("\(r.failed.count) could not be downloaded") }
                if !r.withdrawn.isEmpty { parts.append("\(r.withdrawn.count) withdrawn from the catalogue") }
                lastSync = parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")
            }
            await reload()
        }
    }

    /// Clean Up Old Downloads: the same safe rules as the automatic cleanup.
    func cleanUp() {
        Task {
            let removed = await library.cleanUp()
            lastSync = removed.isEmpty ? "Nothing to clean up" : "Cleaned up \(removed.count) old download\(removed.count == 1 ? "" : "s")"
            await reload()
        }
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            reloadPending = false
            await reload()
        }
    }

    private func reload() async {
        let snap = await library.snapshot()
        var list: [LibraryItem] = []
        if let h1 = LibraryItem.builtinH1(screenshot: builtinShot) { list.append(h1) }
        for e in snap.entries {
            var it = LibraryItem(e, base: library.base)
            it.isNew = NewBadge.isNew(added: e.entry.added, since: snap.catalogueSince)
            list.append(it)
        }
        items = list
        withdrawnItems = snap.withdrawn.compactMap { LibraryItem(withdrawn: $0, paths: library.paths) }
        if section == .withdrawn && withdrawnItems.isEmpty { section = .all }
        if case .category(let c) = section, !categoryNames.contains(c), !list.isEmpty { section = .all }
        if selection == nil || item(selection) == nil { select(visible.first?.id ?? list.first?.id) }

        let total = snap.entries.count
        let have = snap.entries.filter { $0.availability == .installed }.count
        let busy = snap.entries.filter(\.downloading).count
        var line = total == 0 ? "No catalogue downloaded yet" : "\(total) firmwares · \(have) downloaded"
        if busy > 0 { line += " · downloading \(busy)" }
        if let u = snap.catalogueUpdated {
            let date = ISO8601DateFormatter.withFractions.date(from: u) ?? ISO8601DateFormatter().date(from: u)
            line += " · catalogue " + (date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? u)
        }
        if isRefreshing { line = "Checking for firmware updates… " + line }
        else if !lastSync.isEmpty { line = lastSync + " · " + line }
        status = line
    }

    /// The firmware's bytes: bundled, or from the library (downloaded first, ahead of background downloads, if
    /// needed; an older installed build when offline).
    func playable(for item: LibraryItem) async throws -> PlayableFirmware {
        switch item.source {
        case .builtin(let url):
            let data = try Data(contentsOf: url)
            return PlayableFirmware(data: data, sha256: sha256Hex(data), catalogueID: nil, isFallback: false, version: item.version)
        case .catalogue(let e):
            let p = try await library.firmwareForPlayback(id: e.id)
            return PlayableFirmware(data: p.data, sha256: p.build.sha256, catalogueID: e.id, isFallback: p.isFallback,
                                    version: p.build.version)
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

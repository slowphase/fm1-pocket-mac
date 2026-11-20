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

    var isBuiltin: Bool { if case .builtin = source { return true } else { return false } }

    static func builtinH1() -> LibraryItem? {
        guard let url = Bundle.main.url(forResource: "h1", withExtension: "rfm1"),
              let data = try? Data(contentsOf: url), let f = try? RFM1File(data) else { return nil }
        return LibraryItem(source: .builtin(url), id: "builtin:" + f.id, name: f.name, version: f.version,
                           authors: f.authors.joined(separator: ", "), category: "Built in", tag: "Built into this app",
                           about: "Jake Handy's h1, built into the app so there is always something to play, even offline.",
                           license: f.license, sourceURL: f.sourceURL, imageURL: nil, screenshotFile: nil, size: data.count,
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
    }

    var downloadText: String {
        if downloading { return "Downloading…" }
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

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var status = ""
    @Published private(set) var isRefreshing = false
    @Published var selection: LibraryItem.ID?
    @Published var search = ""

    /// the firmware store: catalogue, downloads, cache, cleanup (PocketKit/FirmwareLibrary.swift)
    let library = FirmwareLibrary()
    private var started = false
    private var reloadPending = false
    private var lastSync = ""

    var filtered: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.name.lowercased().contains(q) || $0.authors.lowercased().contains(q) || $0.tag.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
        }
    }

    var categories: [String] {
        var seen: [String] = []
        for i in filtered where !seen.contains(i.category) { seen.append(i.category) }
        return seen.sorted { a, b in a == "Built in" ? true : (b == "Built in" ? false : a < b) }
    }

    func item(_ id: LibraryItem.ID?) -> LibraryItem? { items.first { $0.id == id } }

    /// Shows the cached library at once, then synchronises in the background.
    func start() {
        guard !started else { return }
        started = true
        let lib = library
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
        if let h1 = LibraryItem.builtinH1() { list.append(h1) }
        list += snap.entries.map { LibraryItem($0, base: library.base) }
        items = list
        if selection == nil || item(selection) == nil { selection = list.first?.id }

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

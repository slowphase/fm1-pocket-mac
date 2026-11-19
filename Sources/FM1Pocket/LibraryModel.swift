import Foundation
import PocketKit

/// One firmware the library shows: the built-in h1 or a catalogue entry.
struct LibraryItem: Identifiable, Hashable {
    enum Source: Hashable {
        case builtin(URL)
        case catalogue(CatalogueEntry)
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
    let size: Int

    var isBuiltin: Bool { if case .builtin = source { return true } else { return false } }

    static func builtinH1() -> LibraryItem? {
        guard let url = Bundle.main.url(forResource: "h1", withExtension: "rfm1"),
              let data = try? Data(contentsOf: url), let f = try? RFM1File(data) else { return nil }
        return LibraryItem(source: .builtin(url), id: "builtin:" + f.id, name: f.name, version: f.version,
                           authors: f.authors.joined(separator: ", "), category: "Built in", tag: "Built into this app",
                           about: "Jake Handy's h1, built into the app so there is always something to play, even offline.",
                           license: f.license, sourceURL: f.sourceURL, imageURL: nil, size: data.count)
    }

    init(source: Source, id: String, name: String, version: String, authors: String, category: String, tag: String,
         about: String, license: String, sourceURL: String?, imageURL: URL?, size: Int) {
        self.source = source; self.id = id; self.name = name; self.version = version; self.authors = authors
        self.category = category; self.tag = tag; self.about = about; self.license = license
        self.sourceURL = sourceURL; self.imageURL = imageURL; self.size = size
    }

    init(entry e: CatalogueEntry, service: CatalogueService) {
        var src = e.source
        if let s = src, let c = e.commit { src = s + "/tree/" + c }
        self.init(source: .catalogue(e), id: "cat:" + e.id, name: e.name, version: e.version, authors: e.authorLine,
                  category: e.category, tag: e.tag, about: e.about, license: e.license, sourceURL: src,
                  imageURL: service.imageURL(for: e), size: e.size)
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var status = ""
    @Published private(set) var isRefreshing = false
    @Published var selection: LibraryItem.ID?
    @Published var search = ""

    let service = CatalogueService()
    private var started = false

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

    func start() {
        guard !started else { return }
        started = true
        if let cached = service.cachedCatalogue() { apply(cached, note: "Offline copy of the catalogue") }
        else { apply(nil, note: "") }
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        status = "Checking for firmware updates…"
        Task {
            do {
                let c = try await service.fetchCatalogue()
                apply(c, note: "")
            } catch {
                status = (service.cachedCatalogue() != nil ? "Offline: showing the last downloaded catalogue. " : "")
                    + "Could not reach the catalogue (\(error.localizedDescription))"
            }
            isRefreshing = false
        }
    }

    private func apply(_ c: Catalogue?, note: String) {
        var list: [LibraryItem] = []
        if let h1 = LibraryItem.builtinH1() { list.append(h1) }
        if let c {
            list += c.firmwares.map { LibraryItem(entry: $0, service: service) }
            let date = ISO8601DateFormatter.withFractions.date(from: c.updated) ?? ISO8601DateFormatter().date(from: c.updated)
            let when = date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? c.updated
            status = (note.isEmpty ? "" : note + " · ") + "\(c.firmwares.count) firmwares · catalogue updated \(when)"
        }
        items = list
        if selection == nil || item(selection) == nil { selection = list.first?.id }
    }

    /// The firmware's bytes: bundled, cached, or downloaded and checked against the catalogue's SHA-256.
    func bytes(for item: LibraryItem) async throws -> Data {
        switch item.source {
        case .builtin(let url): return try Data(contentsOf: url)
        case .catalogue(let e): return try await service.firmware(for: e)
        }
    }

    func isDownloaded(_ item: LibraryItem) -> Bool {
        switch item.source {
        case .builtin: return true
        case .catalogue(let e): return service.isCached(e)
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

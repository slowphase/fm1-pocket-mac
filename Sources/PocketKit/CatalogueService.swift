import CryptoKit
import Foundation

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Where the app keeps its files: `~/Library/Application Support/FM-1 Pocket/` unless a test gives another folder.
public enum PocketPaths {
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FM-1 Pocket", isDirectory: true)
    }
}

/// Reads FM-1 Pocket Player's published catalogue and downloads its firmware. Nothing here duplicates Pocket's
/// pipeline: it only fetches what Pocket's nightly job has already approved, tested and published.
///
/// Everything is cached: the last good catalogue (used when offline) and each firmware file, stored under the
/// catalogue's own file name (which contains the first 8 hex digits of its SHA-256, so an update is a new file).
/// A download is kept only if its SHA-256 matches the catalogue.
public final class CatalogueService: @unchecked Sendable {
    public static let defaultBase = URL(string: "https://slowphase.github.io/fm1-pocket-player/data/")!

    public let base: URL
    public let cacheDir: URL
    private let session: URLSession

    public init(base: URL = CatalogueService.defaultBase,
                cacheDir: URL = PocketPaths.appSupport.appendingPathComponent("Catalogue", isDirectory: true),
                session: URLSession = .shared) {
        self.base = base
        self.cacheDir = cacheDir
        self.session = session
    }

    private var catalogueFile: URL { cacheDir.appendingPathComponent("catalog.json") }
    private var firmwareDir: URL { cacheDir.appendingPathComponent("fw", isDirectory: true) }

    public func url(for relative: String) -> URL {
        URL(string: relative, relativeTo: base)?.absoluteURL ?? base.appendingPathComponent(relative)
    }
    public func imageURL(for entry: CatalogueEntry) -> URL? { entry.image.map { url(for: $0) } }

    /// The last catalogue that downloaded and decoded successfully, if any.
    public func cachedCatalogue() -> Catalogue? {
        guard let data = try? Data(contentsOf: catalogueFile) else { return nil }
        return try? Catalogue.decode(data)
    }

    /// Downloads the catalogue. Only a catalogue that decodes replaces the cached one.
    public func fetchCatalogue() async throws -> Catalogue {
        var req = URLRequest(url: url(for: "catalog.json"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw PocketError.http(http.statusCode, "the catalogue") }
        let catalogue = try Catalogue.decode(data)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try data.write(to: catalogueFile, options: .atomic)
        return catalogue
    }

    public func cachedFirmwareURL(for entry: CatalogueEntry) -> URL {
        firmwareDir.appendingPathComponent((entry.file as NSString).lastPathComponent)
    }

    /// The firmware's bytes from the cache, only if they still match the catalogue's checksum.
    public func cachedFirmware(for entry: CatalogueEntry) -> Data? {
        guard let data = try? Data(contentsOf: cachedFirmwareURL(for: entry)), sha256Hex(data) == entry.sha256 else { return nil }
        return data
    }

    public func isCached(_ entry: CatalogueEntry) -> Bool {
        FileManager.default.fileExists(atPath: cachedFirmwareURL(for: entry).path)
    }

    /// The firmware's bytes: from the cache, or downloaded, checked against the catalogue's SHA-256 and cached.
    public func firmware(for entry: CatalogueEntry) async throws -> Data {
        if let data = cachedFirmware(for: entry) { return data }
        var req = URLRequest(url: url(for: entry.file))
        req.timeoutInterval = 60
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw PocketError.http(http.statusCode, entry.name) }
        try Self.verify(data, sha256: entry.sha256, name: entry.name)
        try FileManager.default.createDirectory(at: firmwareDir, withIntermediateDirectories: true)
        try data.write(to: cachedFirmwareURL(for: entry), options: .atomic)
        return data
    }

    public static func verify(_ data: Data, sha256 expected: String, name: String) throws {
        guard sha256Hex(data) == expected.lowercased() else { throw PocketError.checksumMismatch(name) }
    }
}

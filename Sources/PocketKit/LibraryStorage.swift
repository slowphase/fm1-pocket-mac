import Foundation

// MARK: - Where everything lives

/// The app's folders, split strictly into app-managed downloads (only `Managed/` and the Milestone 1 `Catalogue/`
/// cache, which automatic cleanup may touch) and user-owned data (never deleted or overwritten by sync or cleanup).
///
///     <root>/                              ~/Library/Application Support/FM-1 Pocket/
///       Managed/                           app-managed
///         catalog.json                     the last catalogue that downloaded and validated
///         catalog-v2.json                  the same for the expanded catalogue (preferred when present)
///         registry.json, registry.bak.json what is installed (see Registry)
///         firmware/<id>/<sha256>.rfm1      verified firmware builds, named by their content hash
///         shots/<name>.png                 screenshots, named as the catalogue names them
///         tmp/                             downloads in progress
///         generated/<sha>.png              screenshots the app made itself (built-in h1, imports)
///       State/                             user: saved settings (flash images), see StateStore
///       Imported/                          user: imported .rfm1 files
///       UserData/                          user: favourites and other small preferences
///       Catalogue/                         Milestone 1's old download cache (app-managed, cleaned up)
public struct LibraryPaths: Sendable {
    public let root: URL

    public init(root: URL = PocketPaths.appSupport) { self.root = root.standardizedFileURL }

    public var managed: URL { root.appendingPathComponent("Managed", isDirectory: true) }
    public var catalogue: URL { managed.appendingPathComponent("catalog.json") }
    /// the last catalog-v2.json that downloaded and validated (preferred over catalog.json when present)
    public var catalogueV2: URL { managed.appendingPathComponent("catalog-v2.json") }
    public var registry: URL { managed.appendingPathComponent("registry.json") }
    public var registryBackup: URL { managed.appendingPathComponent("registry.bak.json") }
    public var firmware: URL { managed.appendingPathComponent("firmware", isDirectory: true) }
    public var shots: URL { managed.appendingPathComponent("shots", isDirectory: true) }
    public var tmp: URL { managed.appendingPathComponent("tmp", isDirectory: true) }
    /// screenshots the app makes itself (built-in and imported firmware); cleanup never looks here
    public var generated: URL { managed.appendingPathComponent("generated", isDirectory: true) }
    public var legacyCatalogue: URL { root.appendingPathComponent("Catalogue", isDirectory: true) }

    public var state: URL { root.appendingPathComponent("State", isDirectory: true) }
    public var imported: URL { root.appendingPathComponent("Imported", isDirectory: true) }
    public var userData: URL { root.appendingPathComponent("UserData", isDirectory: true) }

    /// `firmware/<id>/<sha256>.rfm1`, relative to `managed`. Both parts must already be validated.
    public static func firmwareRelativePath(id: String, sha256: String) -> String { "firmware/\(id)/\(sha256).rfm1" }

    public func firmwareFile(id: String, sha256: String) -> URL {
        managed.appendingPathComponent(Self.firmwareRelativePath(id: id, sha256: sha256))
    }
    public func screenshotFile(_ name: String) -> URL { shots.appendingPathComponent(name) }

    /// true when `url` is inside `folder` (after resolving `..` and symlinks in the path)
    public static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let f = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }
}

// MARK: - Names from the catalogue are checked before they touch the disk or a URL

public enum SafeName {
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    /// one path component: letters, digits, `.`, `_`, `-`; not `.`/`..`, not hidden, at most 128 characters
    public static func isComponent(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && !s.hasPrefix(".") && s.allSatisfy { allowed.contains($0) }
    }
    /// a firmware id usable as a folder name
    public static func isID(_ s: String) -> Bool { s.count <= 64 && isComponent(s) }
    /// a lower-case SHA-256
    public static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
    /// a relative path like `fw/amb-8a5014a6.rfm1`: safe components joined by `/`, nothing that climbs out
    public static func isRelativePath(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 512, !s.hasPrefix("/") else { return false }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.allSatisfy(isComponent)
    }
    /// the last component of a relative path (already validated)
    public static func lastComponent(_ s: String) -> String { s.split(separator: "/").last.map(String.init) ?? s }
    /// any string made safe for use as a file name (for ids from imported files)
    public static func sanitized(_ s: String) -> String {
        var out = String(s.map { allowed.contains($0) ? $0 : "_" }.prefix(64))
        while out.hasPrefix(".") { out = "_" + String(out.dropFirst()) }
        return out.isEmpty ? "_" : out
    }
}

extension Catalogue {
    /// Keeps only entries whose id, checksum and paths are safe to use, and the first of any repeated id. A missing
    /// or unsafe screenshot path just drops the screenshot. Throws if nothing usable is left, so a broken or empty
    /// catalogue can never replace a good one.
    public func validated() throws -> Catalogue {
        var seen = Set<String>()
        var out: [CatalogueEntry] = []
        for var e in firmwares {
            guard SafeName.isID(e.id), SafeName.isSHA256(e.sha256), SafeName.isRelativePath(e.file), !seen.contains(e.id) else { continue }
            if let img = e.image, !SafeName.isRelativePath(img) { e.image = nil }
            seen.insert(e.id)
            out.append(e)
        }
        guard !out.isEmpty else { throw PocketError.badCatalogue("it lists no usable firmware") }
        var c = self
        c.firmwares = out
        return c
    }
}

// MARK: - The registry: what is installed

public enum BuildOrigin: String, Codable, Sendable { case catalogue, imported }

/// One verified firmware build on disk. A build is its content: two files with the same SHA-256 are the same build,
/// whatever their version strings say, and two different hashes are different builds even with the same version.
public struct InstalledBuild: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var sha256: String
    /// relative to `Managed/` (catalogue builds) or `Imported/` (imports)
    public var file: String
    public var size: Int
    public var installedAt: Date
    public var origin: BuildOrigin
    /// the cached screenshot's file name in `Managed/shots`, if there is one
    public var screenshot: String?
    public var lastUsedAt: Date?

    public init(id: String, name: String, version: String, sha256: String, file: String, size: Int, installedAt: Date,
                origin: BuildOrigin, screenshot: String? = nil, lastUsedAt: Date? = nil) {
        self.id = id; self.name = name; self.version = version; self.sha256 = sha256; self.file = file
        self.size = size; self.installedAt = installedAt; self.origin = origin; self.screenshot = screenshot
        self.lastUsedAt = lastUsedAt
    }
}

public enum ListingStatus: String, Codable, Sendable {
    /// in the latest catalogue
    case listed
    /// was in the catalogue and is no longer: never re-downloaded, files and saves kept
    case withdrawn
}

/// Everything known about one catalogue firmware.
public struct FirmwareRecord: Codable, Equatable, Sendable {
    public var id: String
    /// managed builds, most recently installed first: [current, previous]. Never more than two.
    public var builds: [InstalledBuild]
    public var status: ListingStatus
    public var statusChangedAt: Date?
    /// its catalogue entry when last listed (so a withdrawn firmware can still be described offline)
    public var entry: CatalogueEntry?
    /// the last download problem, cleared by a successful install
    public var lastError: String?
    /// set when this firmware's current build has no saved settings but another build of it does: the build key
    /// of that other save. Nothing is copied; a later interface can offer to.
    public var stateFromOtherBuild: String?

    public init(id: String, builds: [InstalledBuild] = [], status: ListingStatus = .listed, entry: CatalogueEntry? = nil) {
        self.id = id; self.builds = builds; self.status = status; self.entry = entry
    }

    public var current: InstalledBuild? { builds.first }
    public var previous: InstalledBuild? { builds.count > 1 ? builds[1] : nil }
}

public struct Registry: Codable, Equatable, Sendable {
    public static let keep = 2
    public var schema = 1
    public var firmwares: [String: FirmwareRecord] = [:]
    /// imported files (user-owned, in `Imported/`), never removed by sync or cleanup
    public var imports: [InstalledBuild] = []

    public init() {}

    /// Puts `build` first for its firmware (moving it up if it is already there) and keeps at most two builds.
    /// Returns the builds that dropped out of the two kept.
    @discardableResult
    public mutating func install(_ build: InstalledBuild) -> [InstalledBuild] {
        var rec = firmwares[build.id] ?? FirmwareRecord(id: build.id)
        var builds = rec.builds.filter { $0.sha256 != build.sha256 }
        builds.insert(build, at: 0)
        let dropped = Array(builds.dropFirst(Self.keep))
        rec.builds = Array(builds.prefix(Self.keep))
        rec.lastError = nil
        firmwares[build.id] = rec
        return dropped
    }

    /// every managed build kept by the two-version rule
    public var retainedBuilds: [InstalledBuild] { firmwares.values.flatMap(\.builds) }
}

public enum RegistryLoad: String, Sendable {
    case fresh, loaded, fromBackup, rebuilt
}

/// Reads and writes the registry. A write goes to a temporary file and is renamed into place; the previous good
/// registry is kept as `registry.bak.json`. On load a damaged registry falls back to the backup, and if both are
/// damaged it is rebuilt from the verified files on disk, so metadata trouble never costs a firmware file.
public struct RegistryStore {
    public let paths: LibraryPaths

    public init(paths: LibraryPaths) { self.paths = paths }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static func decode(_ url: URL) -> Registry? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let r = try? dec.decode(Registry.self, from: d), r.schema == 1 else { return nil }
        return r
    }

    public func load(catalogue: Catalogue?) -> (Registry, RegistryLoad) {
        if let r = Self.decode(paths.registry) { return (r, .loaded) }
        if let r = Self.decode(paths.registryBackup) { return (r, .fromBackup) }
        let fm = FileManager.default
        let anything = fm.fileExists(atPath: paths.registry.path) || fm.fileExists(atPath: paths.registryBackup.path)
            || fm.fileExists(atPath: paths.firmware.path) || fm.fileExists(atPath: paths.imported.path)
        guard anything else { return (Registry(), .fresh) }
        return (rebuild(catalogue: catalogue), .rebuilt)
    }

    public func save(_ r: Registry) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.managed, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(r)
        if let good = try? Data(contentsOf: paths.registry), Self.decode(paths.registry) != nil {
            try good.write(to: paths.registryBackup, options: .atomic)     // keep the last good one as the backup
        }
        try data.write(to: paths.registry, options: .atomic)
    }

    /// What can be established from disk alone: every `firmware/<id>/<sha>.rfm1` whose content still matches its
    /// name (the catalogue's current build first, then newest first, at most two per firmware), and every valid
    /// `.rfm1` in `Imported/`. Files that do not verify are left out (and later cleaned up as invalid).
    public func rebuild(catalogue: Catalogue?) -> Registry {
        let fm = FileManager.default
        var r = Registry()
        let listed = Dictionary((catalogue?.firmwares ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = (try? fm.contentsOfDirectory(atPath: paths.firmware.path)) ?? []
        for id in ids where SafeName.isID(id) {
            let dir = paths.firmware.appendingPathComponent(id, isDirectory: true)
            var found: [InstalledBuild] = []
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard name.hasSuffix(".rfm1") else { continue }
                let sha = String(name.dropLast(5))
                let url = dir.appendingPathComponent(name)
                guard SafeName.isSHA256(sha), let data = try? Data(contentsOf: url), sha256Hex(data) == sha else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let e = listed[id]
                let manifest = try? RFM1File(data)
                let version = e?.sha256 == sha ? e!.version : (manifest?.version ?? "")
                found.append(InstalledBuild(id: id, name: e?.name ?? manifest?.name ?? id, version: version, sha256: sha,
                                            file: LibraryPaths.firmwareRelativePath(id: id, sha256: sha), size: data.count,
                                            installedAt: date, origin: .catalogue,
                                            screenshot: e?.image.map(SafeName.lastComponent)))
            }
            found.sort { a, b in
                let ac = listed[id]?.sha256 == a.sha256, bc = listed[id]?.sha256 == b.sha256
                if ac != bc { return ac }
                return a.installedAt > b.installedAt
            }
            guard !found.isEmpty else { continue }
            var rec = FirmwareRecord(id: id, builds: Array(found.prefix(Registry.keep)),
                                     status: listed[id] == nil ? .withdrawn : .listed, entry: listed[id])
            rec.statusChangedAt = Date()
            r.firmwares[id] = rec
        }
        for name in ((try? fm.contentsOfDirectory(atPath: paths.imported.path)) ?? []).sorted() where name.hasSuffix(".rfm1") {
            let url = paths.imported.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let f = try? RFM1File(data) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            r.imports.append(InstalledBuild(id: f.id, name: f.name, version: f.version, sha256: sha256Hex(data), file: name,
                                            size: data.count, installedAt: date, origin: .imported))
        }
        return r
    }
}

// MARK: - Favourites (user-owned)

/// The firmware ids the user starred, in `UserData/favourites.json`. Sync and cleanup never touch it.
public struct FavouritesStore {
    public let file: URL

    public init(paths: LibraryPaths = LibraryPaths()) { file = paths.userData.appendingPathComponent("favourites.json") }

    public func load() -> Set<String> {
        guard let d = try? Data(contentsOf: file), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }
    public func save(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ids.sorted()).write(to: file, options: .atomic)
    }
}

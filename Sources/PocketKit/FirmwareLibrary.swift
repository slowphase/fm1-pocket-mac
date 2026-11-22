import Foundation

/// The firmware library: keeps a local, offline-capable copy of FM-1 Pocket Player's approved firmware and their
/// screenshots, in step with Pocket's published catalogue, keeping the current and one previous build of each.
///
/// It only consumes what Pocket publishes (`catalog.json`, `fw/…`, `shots/…`); it never discovers firmware itself.
/// Files are written to `Managed/tmp` and moved into place only after their SHA-256 matches the catalogue. Each
/// install is committed to the registry on its own, so an interrupted sync leaves every finished install usable and
/// everything else as it was. Cleanup only ever deletes files inside `Managed/` (and Milestone 1's old cache) that
/// the two-version rule no longer keeps, and never a firmware that is playing. See docs/STORAGE.md.
public actor FirmwareLibrary {
    public nonisolated let paths: LibraryPaths
    public nonisolated let base: URL
    private let fetcher: HTTPFetching
    public nonisolated let scheduler: DownloadScheduler
    private let store: RegistryStore

    public private(set) var registry: Registry
    /// the firmware this app downloads and plays (from v2's Mac-downloadable entries, or from catalog.json)
    public private(set) var catalogue: Catalogue?
    /// the expanded catalogue, when the last good catalogue came from catalog-v2.json
    public private(set) var discovery: CatalogueV2?
    public nonisolated let registryLoad: RegistryLoad

    private var inflight: [String: Task<InstalledBuild, Error>] = [:]     // by firmware id and sha256
    private var shotInflight: [String: Task<Bool, Never>] = [:]           // by screenshot name
    private var downloadingIDs: Set<String> = []
    private var active: [String: Int] = [:]                               // sha256 -> number of players
    private var syncing = false
    private var onChange: (@Sendable () -> Void)?

    /// emu blocks for a catalogue that does not publish them yet (test builds only; see CatalogueV2.withPreview)
    private let emuPreview: Data?

    public init(paths: LibraryPaths = LibraryPaths(), base: URL = CatalogueService.defaultBase,
                fetcher: HTTPFetching = URLSessionFetcher(), scheduler: DownloadScheduler = DownloadScheduler(limit: 2),
                emuPreview: Data? = nil) {
        self.paths = paths
        self.base = base
        self.fetcher = fetcher
        self.scheduler = scheduler
        self.store = RegistryStore(paths: paths)
        self.emuPreview = emuPreview
        let v2 = Self.readCachedV2(paths)?.withPreview(emuPreview)
        let v2cat = v2.flatMap { try? $0.macCatalogue() }
        let cat = v2cat ?? Self.readCachedCatalogue(paths)
        self.catalogue = cat
        self.discovery = v2cat == nil ? nil : v2
        var (reg, how) = RegistryStore(paths: paths).load(catalogue: cat)
        if how == .fromBackup { reg = Self.reconcile(reg, catalogue: cat, paths: paths) }
        self.registry = reg
        self.registryLoad = how
        if how == .rebuilt || how == .fromBackup { try? RegistryStore(paths: paths).save(reg) }
    }

    /// The backup registry can be one install behind. Adds any catalogue build whose verified file is already in
    /// place but missing from the registry (as that firmware's current build).
    static func reconcile(_ r: Registry, catalogue: Catalogue?, paths: LibraryPaths) -> Registry {
        var r = r
        for e in catalogue?.firmwares ?? [] where r.firmwares[e.id]?.current?.sha256 != e.sha256 {
            let u = paths.firmwareFile(id: e.id, sha256: e.sha256)
            guard let d = try? Data(contentsOf: u), sha256Hex(d) == e.sha256 else { continue }
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            r.install(InstalledBuild(id: e.id, name: e.name, version: e.version, sha256: e.sha256,
                                     file: LibraryPaths.firmwareRelativePath(id: e.id, sha256: e.sha256), size: d.count,
                                     installedAt: date, origin: .catalogue, screenshot: e.image.map(SafeName.lastComponent)))
            r.firmwares[e.id]?.entry = e
        }
        return r
    }

    private static func readCachedV2(_ paths: LibraryPaths) -> CatalogueV2? {
        guard let d = try? Data(contentsOf: paths.catalogueV2) else { return nil }
        return try? CatalogueV2.decode(d)
    }

    private static func readCachedCatalogue(_ paths: LibraryPaths) -> Catalogue? {
        guard let d = try? Data(contentsOf: paths.catalogue) else { return nil }
        return try? Catalogue.decode(d).validated()
    }

    public func setOnChange(_ f: (@Sendable () -> Void)?) { onChange = f }
    private func changed() { onChange?() }

    // MARK: - What the library shows

    public enum Availability: Equatable, Sendable {
        /// the catalogue's current build is on disk
        case installed
        /// an older build is on disk; the catalogue's current build is not (yet)
        case olderInstalled
        case notDownloaded
    }

    public struct Entry: Equatable, Sendable {
        public var entry: CatalogueEntry
        public var availability: Availability
        public var downloading: Bool
        public var lastError: String?
        public var current: InstalledBuild?
        public var previous: InstalledBuild?
        /// the cached screenshot, when it is on disk
        public var screenshotFile: URL?
        /// what the expanded catalogue says about it on the Mac (nil with catalog.json)
        public var mac: CatalogueV2.Status?
        public var makers: [CatalogueV2.Maker] = []
        public var hubURL: String?
        /// the emulator engine's view of this firmware (catalog-v2.json's emu block), when the catalogue has one
        public var emu: CatalogueV2.Emu?
        /// the engine recommended on this Mac ("rfm1" or "fm1-emu"), and why
        public var preferredEngine: String?
        public var preferredReason: String?
        /// how sure Pocket is of this entry's engine on the Mac, and the listening tests behind it
        public var confidence: CatalogueV2.Confidence?
        public var listened: [CatalogueV2.Emu.Listened] = []
        /// the firmware's latest release and the day it first appeared in the library (discovery)
        public var release: CatalogueV2.Release?
        public var listed: String?
    }

    public struct Snapshot: Equatable, Sendable {
        public var entries: [Entry]               // listed firmware, in catalogue order
        public var withdrawn: [FirmwareRecord]
        public var imports: [InstalledBuild]
        public var catalogueUpdated: String?
        /// the catalogue's `since` (its first day), for the "new" badge
        public var catalogueSince: String?
        public var registryLoad: RegistryLoad
        /// firmware the expanded catalogue lists that this app cannot download (source-only, unsupported...)
        public var more: [CatalogueV2.Entry] = []
        /// The Firmware Hub's credit, when the catalogue used its list
        public var attribution: CatalogueV2.Attribution?
        /// "v2" or "v1": which feed the library came from
        public var feed: String = "v1"
    }

    public func snapshot() -> Snapshot {
        let fm = FileManager.default
        var out: [Entry] = []
        for e in catalogue?.firmwares ?? [] {
            let rec = registry.firmwares[e.id]
            let builds = (rec?.builds ?? []).filter { fm.fileExists(atPath: managedURL($0).path) }
            let avail: Availability = builds.first?.sha256 == e.sha256 ? .installed : (builds.isEmpty ? .notDownloaded : .olderInstalled)
            let d = discovery?.entry(e.baseID)
            out.append(Entry(entry: e, availability: avail, downloading: downloadingIDs.contains(e.id), lastError: rec?.lastError,
                             current: builds.first, previous: builds.count > 1 ? builds[1] : nil,
                             screenshotFile: localScreenshot(for: e), mac: e.isPackage ? d?.emu?.mac : d?.mac,
                             makers: d?.makers ?? [], hubURL: d?.hubURL, emu: d?.emu,
                             preferredEngine: d?.preferredMacEngine, preferredReason: d?.preferredMacReason,
                             confidence: d?.confidence[e.isPackage ? "fm1-emu" : "rfm1"],
                             listened: (d?.listened ?? []).filter { ($0.player ?? "mac") == "mac" && $0.engine == (e.isPackage ? "fm1-emu" : "rfm1") },
                             release: d?.release, listed: d?.listed))
        }
        let withdrawn = registry.firmwares.values.filter { $0.status == .withdrawn }.sorted { $0.id < $1.id }
        return Snapshot(entries: out, withdrawn: withdrawn, imports: registry.imports, catalogueUpdated: catalogue?.updated,
                        catalogueSince: catalogue?.since, registryLoad: registryLoad, more: discovery?.notDownloadable ?? [],
                        attribution: discovery?.attribution, feed: discovery == nil ? "v1" : "v2")
    }

    public func localScreenshot(for e: CatalogueEntry) -> URL? {
        guard let img = e.image, SafeName.isRelativePath(img) else { return nil }
        let u = paths.screenshotFile(SafeName.lastComponent(img))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public func managedURL(_ b: InstalledBuild) -> URL {
        b.origin == .imported ? paths.imported.appendingPathComponent(b.file) : paths.managed.appendingPathComponent(b.file)
    }

    // MARK: - Synchronisation

    public struct SyncReport: Equatable, Sendable {
        /// set when the catalogue could not be fetched or was refused (offline, server error, bad data):
        /// nothing was changed and no cleanup ran
        public var catalogueError: String?
        public var installed: [String] = []
        public var failed: [String: String] = [:]
        public var withdrawn: [String] = []
        public var screenshotsDownloaded = 0
        public var cleaned: [CleanupCandidate] = []
        public var skippedBecauseBusy = false
        /// which feed this sync used: "v2" (catalog-v2.json) or "v1" (catalog.json)
        public var feed: String?
    }

    /// catalog-v2.json if the site has a usable one, else catalog.json (as builds up to 19 read it). Only a feed
    /// that downloads and validates replaces the cached one; a v1 fallback retires the cached v2.
    private func fetchCatalogues() async throws -> (Catalogue, CatalogueV2?) {
        let fm = FileManager.default
        let v2url = try url(for: "catalog-v2.json")
        if let got = try? await fetcher.fetch(v2url), got.1 == 200,
           let v2 = (try? CatalogueV2.decode(got.0))?.withPreview(emuPreview), let cat = try? v2.macCatalogue() {
            try fm.createDirectory(at: paths.managed, withIntermediateDirectories: true)
            try got.0.write(to: paths.catalogueV2, options: .atomic)
            return (cat, v2)
        }
        let (data, code) = try await fetcher.fetch(url(for: "catalog.json"))
        guard code == 200 else { throw PocketError.http(code, "the catalogue") }
        let cat = try Catalogue.decode(data).validated()
        try fm.createDirectory(at: paths.managed, withIntermediateDirectories: true)
        try data.write(to: paths.catalogue, options: .atomic)
        if fm.fileExists(atPath: paths.catalogueV2.path) { try? fm.removeItem(at: paths.catalogueV2) }
        return (cat, nil)
    }

    /// Fetches the catalogue, downloads every missing or changed firmware and screenshot (two at a time), records
    /// withdrawals, then cleans up. Safe to call while another sync runs (the second call returns at once).
    public func sync() async -> SyncReport {
        var report = SyncReport()
        guard !syncing else { report.skippedBecauseBusy = true; return report }
        syncing = true
        defer { syncing = false }

        let fresh: Catalogue
        do {
            let got = try await fetchCatalogues()
            fresh = got.0
            discovery = got.1
            report.feed = got.1 == nil ? "v1" : "v2"
        } catch {
            report.catalogueError = error.localizedDescription
            changed()
            return report
        }
        catalogue = fresh
        report.withdrawn = applyListing(fresh)
        changed()

        // a firmware with both a build and an original package: only the engine the catalogue prefers is downloaded in
        // the background; the other comes when it is chosen (and stays once it is there)
        let entries = fresh.firmwares.filter { e in
            guard let alt = discovery?.alternative(for: e.id), registry.firmwares[e.id]?.current == nil else { return true }
            return !alt
        }
        let results: [(String, String?, Bool)] = await withTaskGroup(of: (String, String?, Bool).self) { group in
            for e in entries {
                group.addTask {
                    var problem: String?
                    var didInstall = false
                    if await self.needsInstall(e) {
                        do { _ = try await self.ensureInstalled(e, priority: .background); didInstall = true }
                        catch { problem = error.localizedDescription }
                    }
                    _ = await self.ensureScreenshot(e)           // never blocks or fails the firmware
                    return (e.id, problem, didInstall)
                }
            }
            var all: [(String, String?, Bool)] = []
            for await r in group { all.append(r) }
            return all
        }
        for (id, problem, didInstall) in results {
            if let problem { report.failed[id] = problem }
            if didInstall { report.installed.append(id) }
        }
        report.installed.sort()
        report.screenshotsDownloaded = screenshotDownloads
        screenshotDownloads = 0
        report.cleaned = cleanUp()
        changed()
        return report
    }
    private var screenshotDownloads = 0

    /// Marks firmware missing from the new catalogue as withdrawn (keeping their files and saves) and brings back
    /// any that reappear. Returns the newly withdrawn ids.
    private func applyListing(_ c: Catalogue) -> [String] {
        let listed = Set(c.firmwares.map(\.id))
        var withdrawn: [String] = []
        for (id, var rec) in registry.firmwares {
            if !listed.contains(id), rec.status != .withdrawn {
                rec.status = .withdrawn
                rec.statusChangedAt = Date()
                registry.firmwares[id] = rec
                withdrawn.append(id)
            }
        }
        for e in c.firmwares {
            var rec = registry.firmwares[e.id] ?? FirmwareRecord(id: e.id)
            if rec.status != .listed { rec.status = .listed; rec.statusChangedAt = Date() }
            rec.entry = e
            registry.firmwares[e.id] = rec
        }
        try? store.save(registry)
        return withdrawn.sorted()
    }

    private func needsInstall(_ e: CatalogueEntry) -> Bool {
        guard let cur = registry.firmwares[e.id]?.current else { return true }
        return cur.sha256 != e.sha256 || !FileManager.default.fileExists(atPath: managedURL(cur).path)
    }

    /// Makes sure this catalogue build is on disk: already there, adopted from a verified file a crash left behind,
    /// or downloaded. Concurrent requests for the same firmware id and build share one download; different ids
    /// need their own file and registry record even when their bytes match. An interactive request promotes a queued one.
    @discardableResult
    public func ensureInstalled(_ e: CatalogueEntry, priority: DownloadScheduler.Priority = .interactive) async throws -> InstalledBuild {
        guard SafeName.isID(e.id), SafeName.isSHA256(e.sha256), SafeName.isRelativePath(e.file) else {
            throw PocketError.badFirmware("\(e.name): the catalogue entry is not usable.")
        }
        let fm = FileManager.default
        if let rec = registry.firmwares[e.id], let b = rec.builds.first(where: { $0.sha256 == e.sha256 }),
           fm.fileExists(atPath: managedURL(b).path) {
            if rec.current?.sha256 != b.sha256 { registry.install(b); try? store.save(registry); changed() }   // upstream went back to it
            return b
        }
        let dest = paths.firmwareFile(id: e.id, sha256: e.sha256)
        if let data = try? Data(contentsOf: dest), sha256Hex(data) == e.sha256 {    // left by an interrupted sync
            return try commit(e, size: data.count)
        }
        let key = "\(e.id)-\(e.sha256)"
        if let t = inflight[key] {
            if priority == .interactive { await scheduler.promote(tag: key) }
            return try await t.value
        }
        let task = Task { try await self.download(e, key: key, priority: priority) }
        inflight[key] = task
        downloadingIDs.insert(e.id)
        changed()
        do {
            let b = try await task.value
            inflight[key] = nil
            downloadingIDs.remove(e.id)
            changed()
            return b
        } catch {
            inflight[key] = nil
            downloadingIDs.remove(e.id)
            if var rec = registry.firmwares[e.id] { rec.lastError = error.localizedDescription; registry.firmwares[e.id] = rec }
            try? store.save(registry)
            changed()
            throw error
        }
    }

    private func download(_ e: CatalogueEntry, key: String, priority: DownloadScheduler.Priority) async throws -> InstalledBuild {
        // an original package comes from its maker's release, never from Pocket or the Hub; the hash decides
        let source: URL
        if e.isPackage {
            guard let u = e.makerURL else { throw PocketError.badFirmware("\(e.name): the maker's package link is not usable.") }
            source = u
        } else {
            source = try url(for: e.file)
        }
        let granted = await scheduler.acquire(tag: key, priority: priority)
        let result: Result<(Data, Int), Error>
        do { result = .success(try await fetcher.fetch(source)) } catch { result = .failure(error) }
        await scheduler.release(granted)                        // the slot is for the network transfer only
        let (data, code) = try result.get()
        guard code == 200 else { throw PocketError.http(code, e.name) }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.tmp, withIntermediateDirectories: true)
        let tmp = paths.tmp.appendingPathComponent("\(key).download")
        try data.write(to: tmp)
        guard sha256Hex(data) == e.sha256 else {
            try? fm.removeItem(at: tmp)
            throw PocketError.checksumMismatch(e.name)
        }
        let dest = paths.firmwareFile(id: e.id, sha256: e.sha256)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        return try commit(e, size: data.count)
    }

    /// Records a verified file at its final place as the firmware's current build.
    private func commit(_ e: CatalogueEntry, size: Int) throws -> InstalledBuild {
        let b = InstalledBuild(id: e.id, name: e.name, version: e.version, sha256: e.sha256,
                               file: LibraryPaths.firmwareRelativePath(id: e.id, sha256: e.sha256), size: size,
                               installedAt: Date(), origin: .catalogue, screenshot: e.image.map(SafeName.lastComponent))
        registry.install(b)
        var rec = registry.firmwares[e.id]!
        if rec.entry == nil || catalogue?.firmwares.contains(where: { $0.id == e.id }) == true { rec.entry = e }
        registry.firmwares[e.id] = rec
        try store.save(registry)
        return b
    }

    /// Downloads the entry's screenshot if it is not cached. A screenshot is never required: failure just leaves
    /// none. Returns true if it downloaded one.
    @discardableResult
    public func ensureScreenshot(_ e: CatalogueEntry) async -> Bool {
        guard let img = e.image, SafeName.isRelativePath(img) else { return false }
        let name = SafeName.lastComponent(img)
        let dest = paths.screenshotFile(name)
        if FileManager.default.fileExists(atPath: dest.path) { return false }
        if let t = shotInflight[name] { return await t.value }
        let task = Task { await self.downloadScreenshot(path: img, name: name) }
        shotInflight[name] = task
        let ok = await task.value
        shotInflight[name] = nil
        if ok { screenshotDownloads += 1; changed() }
        return ok
    }

    private func downloadScreenshot(path: String, name: String) async -> Bool {
        let tag = "shot:" + name
        let granted = await scheduler.acquire(tag: tag, priority: .background)
        let result = try? await fetcher.fetch(url(for: path))
        await scheduler.release(granted)
        guard let (data, code) = result, code == 200, data.count > 8, data.count < 10_000_000, Self.isImage(data) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: paths.tmp, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.shots, withIntermediateDirectories: true)
            let tmp = paths.tmp.appendingPathComponent(name + ".download")
            try data.write(to: tmp)
            let dest = paths.screenshotFile(name)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
            return true
        } catch {
            return false
        }
    }

    static func isImage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(4))
        return b == [0x89, 0x50, 0x4e, 0x47] || Array(b.prefix(3)) == [0xff, 0xd8, 0xff]
    }

    func url(for relative: String) throws -> URL {
        guard SafeName.isRelativePath(relative), let u = URL(string: relative, relativeTo: base)?.absoluteURL,
              u.absoluteString.hasPrefix(base.absoluteString) else {
            throw PocketError.badCatalogue("unsafe path \(relative)")
        }
        return u
    }

    // MARK: - Playing

    public struct Playable: Sendable {
        public var data: Data
        public var build: InstalledBuild
        /// true when the catalogue's current build could not be had and an older installed build is used instead
        public var isFallback: Bool
    }

    /// The bytes to play for a catalogue firmware: its current build, downloaded first (ahead of any background
    /// downloads) if needed. Offline, or if that fails, the newest installed build that still verifies.
    public func firmwareForPlayback(id: String) async throws -> Playable {
        let listed = catalogue?.firmwares.first { $0.id == id }
        var firstError: Error?
        if let e = listed {
            for _ in 0..<2 {
                do {
                    let b = try await ensureInstalled(e, priority: .interactive)
                    if let data = readVerified(b) { return Playable(data: data, build: b, isFallback: false) }
                } catch {
                    firstError = firstError ?? error
                    break
                }
            }
        }
        for b in registry.firmwares[id]?.builds ?? [] where b.sha256 != listed?.sha256 {
            if let data = readVerified(b) { return Playable(data: data, build: b, isFallback: true) }
        }
        throw firstError ?? PocketError.badFirmware("This firmware has not been downloaded yet, and the catalogue cannot be reached.")
    }

    /// The build's bytes if they still match its hash. A damaged file is dropped from the registry (and so cleaned up).
    private func readVerified(_ b: InstalledBuild) -> Data? {
        if let d = try? Data(contentsOf: managedURL(b)), sha256Hex(d) == b.sha256 { return d }
        if b.origin == .catalogue, var rec = registry.firmwares[b.id] {
            rec.builds.removeAll { $0.sha256 == b.sha256 }
            registry.firmwares[b.id] = rec
            try? store.save(registry)
        }
        return nil
    }

    /// A firmware that is running: cleanup will not delete it until `markInactive`.
    public func markActive(sha256: String) {
        active[sha256, default: 0] += 1
        for (id, var rec) in registry.firmwares {
            if let i = rec.builds.firstIndex(where: { $0.sha256 == sha256 }) {
                rec.builds[i].lastUsedAt = Date()
                registry.firmwares[id] = rec
            }
        }
        try? store.save(registry)
    }
    public func markInactive(sha256: String) {
        if let n = active[sha256], n > 1 { active[sha256] = n - 1 } else { active[sha256] = nil }
    }
    public var activeBuilds: Set<String> { Set(active.keys) }

    /// Notes that this firmware's current build has no saved settings while another build does (`otherKey`, a
    /// StateStore key), or clears the note (nil). Nothing is copied.
    public func noteStateFromOtherBuild(id: String, otherKey: String?) {
        guard var rec = registry.firmwares[id], rec.stateFromOtherBuild != otherKey else { return }
        rec.stateFromOtherBuild = otherKey
        registry.firmwares[id] = rec
        try? store.save(registry)
    }

    // MARK: - Imports (user-owned)

    /// Copies an .rfm1 into `Imported/` (user-owned: never cleaned up, never replaced by catalogue downloads).
    /// Importing the same bytes twice returns the existing import.
    @discardableResult
    public func importFirmware(from url: URL) throws -> InstalledBuild {
        let data = try Data(contentsOf: url)
        let f = try RFM1File(data)
        let sha = sha256Hex(data)
        if let existing = registry.imports.first(where: { $0.sha256 == sha }),
           FileManager.default.fileExists(atPath: managedURL(existing).path) { return existing }
        let name = "\(SafeName.sanitized(f.id))-\(sha.prefix(12)).rfm1"
        let dest = paths.imported.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: paths.imported, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dest.path) { try data.write(to: dest, options: .atomic) }
        let b = InstalledBuild(id: f.id, name: f.name, version: f.version, sha256: sha, file: name, size: data.count,
                               installedAt: Date(), origin: .imported)
        registry.imports.removeAll { $0.sha256 == sha }
        registry.imports.append(b)
        try store.save(registry)
        changed()
        return b
    }

    // MARK: - Cleanup

    /// What cleanup would delete now (nothing is deleted).
    public func cleanupPlan() -> [CleanupCandidate] {
        CleanupPlanner.plan(registry: registry, catalogue: catalogue, paths: paths, active: activeBuilds,
                            busy: Set(inflight.keys.map { "\($0).download" } + shotInflight.keys.map { "\($0).download" }))
    }

    /// Deletes what `cleanupPlan` lists (regular files inside the managed folders only) and returns what went.
    /// The same rules run automatically after a successful sync and from "Clean Up Old Downloads".
    @discardableResult
    public func cleanUp() -> [CleanupCandidate] {
        var done: [CleanupCandidate] = []
        let fm = FileManager.default
        for c in cleanupPlan() {
            guard LibraryPaths.isInside(c.url, paths.managed) || LibraryPaths.isInside(c.url, paths.legacyCatalogue) else { continue }
            guard let v = try? c.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  v.isRegularFile == true || v.isSymbolicLink == true else { continue }
            if (try? fm.removeItem(at: c.url)) != nil { done.append(c) }
        }
        if !done.isEmpty { changed() }
        return done
    }

    // MARK: - Storage use

    public func storageUsage() -> StorageUsage {
        var u = StorageUsage()
        let fm = FileManager.default
        func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var counted = Set<String>()
        for rec in registry.firmwares.values {
            for (i, b) in rec.builds.enumerated() {
                let url = managedURL(b)
                guard fm.fileExists(atPath: url.path) else { continue }
                counted.insert(url.standardizedFileURL.path)
                if i == 0 { u.currentFirmware += size(url) } else { u.previousFirmware += size(url) }
            }
        }
        for url in Self.files(under: paths.firmware) where !counted.contains(url.standardizedFileURL.path) {
            u.awaitingCleanup += size(url)
        }
        u.screenshotsAndMetadata = Self.total(paths.shots) + Self.total(paths.generated) + size(paths.catalogue) + size(paths.catalogueV2)
            + size(paths.registry) + size(paths.registryBackup)
        u.savedStates = Self.total(paths.state) + Self.total(paths.userData)
        u.imported = Self.total(paths.imported)
        u.temporary = Self.total(paths.tmp) + Self.total(paths.legacyCatalogue)
        return u
    }

    static func files(under dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(u) }
        return out
    }
    static func total(_ dir: URL) -> Int64 {
        files(under: dir).reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// Bytes used, by category (for a future Manage Storage window).
public struct StorageUsage: Equatable, Sendable {
    public var currentFirmware: Int64 = 0
    public var previousFirmware: Int64 = 0
    /// managed firmware files no longer kept, deleted at the next cleanup
    public var awaitingCleanup: Int64 = 0
    public var screenshotsAndMetadata: Int64 = 0
    /// saved settings, their backups, and favourites
    public var savedStates: Int64 = 0
    public var imported: Int64 = 0
    /// downloads in progress or abandoned, and Milestone 1's old cache
    public var temporary: Int64 = 0
}

// MARK: - The cleanup planner

public struct CleanupCandidate: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// a managed build the two-version rule no longer keeps
        case superseded
        /// a file in the firmware folder that does not belong there (wrong name, unknown firmware)
        case invalid
        /// a screenshot no kept build or listed firmware uses
        case obsoleteScreenshot
        /// an abandoned download
        case temporary
        /// Milestone 1's old download cache
        case legacyCache
    }
    public var url: URL
    public var reason: Reason
}

/// Works out, without deleting anything, which managed files are no longer needed. It only ever looks inside
/// `Managed/firmware/<id>/`, `Managed/shots/`, `Managed/tmp/` and Milestone 1's `Catalogue/` cache, never
/// recursively beyond those, and never at `State/`, `Imported/` or `UserData/`.
public enum CleanupPlanner {
    public static func plan(registry: Registry, catalogue: Catalogue?, paths: LibraryPaths, active: Set<String>,
                            busy: Set<String> = []) -> [CleanupCandidate] {
        let fm = FileManager.default
        func list(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
        func isFile(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        var out: [CleanupCandidate] = []

        // firmware/<id>/<sha>.rfm1 (and firmware/<id>.fwsc/<sha>.fwsc)
        for id in list(paths.firmware) {
            let dir = paths.firmware.appendingPathComponent(id, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                out.append(CleanupCandidate(url: dir, reason: .invalid))
                continue
            }
            let kept = Set((registry.firmwares[id]?.builds ?? []).map(\.sha256))
            for name in list(dir) {
                let u = dir.appendingPathComponent(name)
                guard isFile(u) else { continue }
                // an original package's folder (`<id>.fwsc`) holds `.fwsc` files, every other one `.rfm1`
                let ext = id.hasSuffix(CatalogueEntry.packageSuffix) ? ".fwsc" : ".rfm1"
                let sha = name.hasSuffix(ext) ? String(name.dropLast(5)) : ""
                if SafeName.isID(id), SafeName.isSHA256(sha) {
                    if kept.contains(sha) || active.contains(sha) { continue }
                    out.append(CleanupCandidate(url: u, reason: registry.firmwares[id] == nil ? .invalid : .superseded))
                } else {
                    out.append(CleanupCandidate(url: u, reason: .invalid))
                }
            }
        }

        // shots/
        var shots = Set(registry.retainedBuilds.compactMap(\.screenshot))
        for e in catalogue?.firmwares ?? [] { if let i = e.image { shots.insert(SafeName.lastComponent(i)) } }
        for name in list(paths.shots) where !shots.contains(name) {
            let u = paths.shots.appendingPathComponent(name)
            if isFile(u) { out.append(CleanupCandidate(url: u, reason: .obsoleteScreenshot)) }
        }

        // tmp/
        for name in list(paths.tmp) where !busy.contains(name) {
            let u = paths.tmp.appendingPathComponent(name)
            if isFile(u) { out.append(CleanupCandidate(url: u, reason: .temporary)) }
        }

        // Milestone 1's cache: Catalogue/catalog.json and Catalogue/fw/*.rfm1 only
        let legacyCat = paths.legacyCatalogue.appendingPathComponent("catalog.json")
        if isFile(legacyCat) { out.append(CleanupCandidate(url: legacyCat, reason: .legacyCache)) }
        let legacyFw = paths.legacyCatalogue.appendingPathComponent("fw", isDirectory: true)
        for name in list(legacyFw) where name.hasSuffix(".rfm1") {
            let u = legacyFw.appendingPathComponent(name)
            if isFile(u) { out.append(CleanupCandidate(url: u, reason: .legacyCache)) }
        }
        return out
    }
}

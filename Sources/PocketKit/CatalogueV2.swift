import Foundation

/// FM-1 Pocket Player's expanded catalogue (`data/catalog-v2.json`, schema 2, built by its `pocket/discover.mjs`).
///
/// Its downloadable entries carry exactly their `catalog.json` fields, so the app downloads the very same files. On top
/// of that it lists every firmware discovered (RemoteFM1FW's builds and The Firmware Hub's list), with each player's
/// status (playable, experimental, unsupported, source-only), the test record behind it, why a firmware cannot be
/// downloaded when it cannot, its makers (linked to their repositories) and where each fact came from.
///
/// The app prefers v2 and falls back to `catalog.json` (schema 1) when v2 is missing, unreadable or unusable. Builds
/// up to 19 only ever read `catalog.json`, which v2 leaves unchanged.
public struct CatalogueV2: Decodable, Equatable {
    public var schema: Int
    public var snapshot: String
    public var updated: String
    public var since: String?
    public var attribution: Attribution?
    public var firmwares: [Entry]

    /// The Firmware Hub's credit, present when the catalogue used the Hub's list (its terms ask for it to be shown)
    public struct Attribution: Codable, Equatable, Sendable {
        public var text: String
        public var url: String
        public var license: String
        public var licenseUrl: String?
        public var changes: String?
        public var read: String?
    }

    public struct Test: Codable, Equatable, Sendable {
        public struct MacOS: Codable, Equatable, Sendable {
            public var date: String?
            public var environment: String?
            public var outcome: String?
            public var speed: Double?
            /// true when this build was not run itself, only the representative sample
            public var sample: Bool?
        }
        public var sha256: String?
        public var runtime: String?
        public var environment: String?
        public var date: String?
        public var outcome: String?
        public var macos: MacOS?
    }

    /// One player's view of a firmware.
    public struct Status: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            case playable, experimental, unsupported, sourceOnly = "source-only"
            /// the emulator engine: no original package this app can fetch, or not distributable by Pocket
            case unavailable
        }
        /// How a Mac status was established.
        public enum Verification: String, Codable, Sendable {
            /// this exact build ran on macOS in the app's engine
            case macos
            /// passed the app's engine on Linux; a representative sample passed on macOS with the same engine version
            case representative
            /// the app's engine on Linux only
            case linux
            case none
        }
        public var state: State
        public var reason: String?
        public var tested: Test?
        public var verification: Verification?
        /// "may-stutter" when the build ran slower than real time in the app's engine
        public var performance: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // a state this app does not know yet is treated as "source-only": shown, never downloaded
            state = (try? c.decode(State.self, forKey: .state)) ?? .sourceOnly
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            tested = try? c.decodeIfPresent(Test.self, forKey: .tested)
            verification = try? c.decodeIfPresent(Verification.self, forKey: .verification)
            performance = try? c.decodeIfPresent(String.self, forKey: .performance)
        }
        public init(state: State, reason: String? = nil, tested: Test? = nil, verification: Verification? = nil, performance: String? = nil) {
            self.state = state; self.reason = reason; self.tested = tested; self.verification = verification; self.performance = performance
        }
        enum CodingKeys: String, CodingKey { case state, reason, tested, verification, performance }

        /// the verification level, worked out from the test record for catalogues that predate the field
        public var macVerification: Verification {
            if let v = verification { return v }
            guard let m = tested?.macos else { return tested == nil ? .none : .linux }
            return m.outcome != nil ? .macos : .representative
        }
        public var mayStutter: Bool { performance == "may-stutter" || (reason ?? "").contains("may stutter") }
    }

    /// The emulator engine's view of a firmware (catalog-v2.json's `emu` block): the maker's original package, run
    /// unchanged on fm1-emu. Its `mac.tested` records are automated boot checks; `listened` are real listening tests,
    /// recorded by hand, and the two are never mixed.
    public struct Emu: Decodable, Equatable, Sendable {
        public struct Package: Codable, Equatable, Sendable {
            /// the maker's release asset (the app downloads it from there)
            public var url: String
            public var sha256: String
            public var size: Int?
            public var version: String?
            public var license: String?
            /// the maker's source at that release
            public var source: String?
            /// Pocket's own copy, for the web player (not used by this app)
            public var file: String?
        }
        public struct Preference: Codable, Equatable, Sendable {
            /// "fm1-emu" or "rfm1"
            public var engine: String
            public var reason: String?
        }
        public struct Listened: Codable, Hashable, Sendable {
            public var player: String?
            public var build: String?
            public var app: String?
            public var area: String?
            public var engine: String?
            public var machine: String?
            public var who: String?
            public var date: String?
            public var verdict: String?
            public var notes: String?
        }
        public struct Tested: Codable, Hashable, Sendable {
            public var engine: String?
            public var date: String?
            public var machine: String?
            public var speed: Double?
            public var intelSpeed: Double?
            public var soundFrom: [String]?
            public var kind: String?
        }
        public var package: Package?
        public var mac: Status
        public var macTested: Tested?
        public var preferredMac: Preference?
        public var listened: [Listened]
        /// set when Pocket may not distribute the package (policy.json's reason)
        public var excluded: String?

        enum CodingKeys: String, CodingKey { case package, mac, preferred, listened, excluded }
        struct Prefs: Decodable { var mac: Preference? }
        struct MacBlock: Decodable { var tested: Tested? }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            package = try? c.decodeIfPresent(Package.self, forKey: .package)
            mac = (try? c.decode(Status.self, forKey: .mac)) ?? Status(state: .unavailable)
            macTested = (try? c.decodeIfPresent(MacBlock.self, forKey: .mac))?.tested
            preferredMac = (try? c.decodeIfPresent(Prefs.self, forKey: .preferred))?.mac
            listened = (try? c.decodeIfPresent([Listened].self, forKey: .listened)) ?? []
            excluded = try? c.decodeIfPresent(String.self, forKey: .excluded)
        }
        public init(package: Package?, mac: Status, macTested: Tested? = nil, preferredMac: Preference? = nil, listened: [Listened] = [], excluded: String? = nil) {
            self.package = package; self.mac = mac; self.macTested = macTested; self.preferredMac = preferredMac
            self.listened = listened; self.excluded = excluded
        }
        /// the package can be downloaded and run by this app
        public var macPlayable: Bool {
            guard let p = package, SafeName.isSHA256(p.sha256.lowercased()), excluded == nil else { return false }
            return (mac.state == .playable || mac.state == .experimental) && URL(string: p.url) != nil
        }
    }

    /// How sure Pocket is that a firmware works on one engine in this app: a person listened to that exact file in
    /// the app (`listened`), it passed the automated checks only (`automated`), or it has a known problem
    /// (`known-issue`). Automated results never count as listened.
    public struct Confidence: Codable, Hashable, Sendable {
        public enum Level: String, Codable, Sendable { case listened, automated, knownIssue = "known-issue" }
        public var level: Level
        public var note: String?
        public init(level: Level, note: String? = nil) { self.level = level; self.note = note }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            level = (try? c.decode(Level.self, forKey: .level)) ?? .automated
            note = try? c.decodeIfPresent(String.self, forKey: .note)
        }
        enum CodingKeys: String, CodingKey { case level, note }
    }
    struct PerPlayer<T: Decodable>: Decodable { var mac: T? }

    /// A firmware's latest release, as its maker published it (from The Firmware Hub's list, or the maker's GitHub
    /// release): never a catalogue, rebuild or commit date.
    public struct Release: Codable, Hashable, Sendable {
        public var version: String?
        /// ISO 8601, e.g. `2026-11-13T04:17:47Z`
        public var date: String
        public var source: String?
        public init(version: String?, date: String, source: String? = nil) { self.version = version; self.date = date; self.source = source }
        public var day: Date? {
            let f = ISO8601DateFormatter()
            return f.date(from: date) ?? NewBadge.date(date)
        }
    }

    public struct Restriction: Codable, Equatable, Sendable {
        public var code: String
        public var reason: String
    }

    public struct Maker: Codable, Equatable, Hashable, Sendable {
        public var name: String
        public var url: String?
    }

    public struct Entry: Decodable, Equatable {
        /// the catalog.json entry, for downloadable builds
        public var download: CatalogueEntry?
        public var id: String
        public var name: String
        public var version: String
        public var authors: [String]
        public var makers: [Maker]
        public var category: String
        public var tag: String
        public var about: String
        public var license: String
        public var source: String?
        public var beta: Bool
        public var web: Status
        public var mac: Status
        public var restriction: Restriction?
        /// The Firmware Hub's page for it, when the Hub lists it
        public var hubURL: String?
        /// the version The Firmware Hub lists
        public var hubVersion: String?
        /// the emulator engine (the maker's original package), when the catalogue has it
        public var emu: Emu?
        /// on the Mac, by engine ("rfm1", "fm1-emu"): how sure Pocket is, and known problems
        public var confidence: [String: Confidence] = [:]
        public var knownIssues: [String: String] = [:]
        /// real listening tests in the apps (both engines, both players), recorded by hand
        public var listened: [Emu.Listened] = []
        /// the firmware's latest release (its version and the date its maker published it), when known
        public var release: Release?
        /// the day it first appeared in the library (`yyyy-MM-dd`): "New to Library" means in the last 14 days
        public var listed: String?
        /// its picture, relative to the catalogue (an .rfm1 build's screen, or its screen as the emulator showed it);
        /// without one the app draws its name
        public var image: String?

        enum CodingKeys: String, CodingKey {
            case id, name, version, authors, makers, category, tag, about, license, source, beta, status, restriction, provenance, file, sha256, emu
            case confidence, knownIssues, listened, release, listed, image
        }
        struct Statuses: Decodable { var web: Status?; var mac: Status? }
        struct Provenance: Decodable {
            struct Hub: Decodable { var url: String?; var version: String? }
            var hub: Hub?
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let ident = try c.decode(String.self, forKey: .id)
            id = ident
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ident
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
            let who = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
            let src = try c.decodeIfPresent(String.self, forKey: .source)
            authors = who
            source = src
            makers = (try? c.decodeIfPresent([Maker].self, forKey: .makers)) ?? who.map { Maker(name: $0, url: src) }
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Other"
            tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
            about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
            license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
            beta = try c.decodeIfPresent(Bool.self, forKey: .beta) ?? false
            let st = try? c.decodeIfPresent(Statuses.self, forKey: .status)
            let unknown = Status(state: .sourceOnly, reason: "This version of the app does not know this firmware's status.")
            web = st?.web ?? unknown
            mac = st?.mac ?? unknown
            restriction = try? c.decodeIfPresent(Restriction.self, forKey: .restriction)
            let prov = try? c.decodeIfPresent(Provenance.self, forKey: .provenance)
            hubURL = prov?.hub?.url
            hubVersion = prov?.hub?.version
            download = c.contains(.file) && c.contains(.sha256) ? try? CatalogueEntry(from: decoder) : nil
            emu = try? c.decodeIfPresent(Emu.self, forKey: .emu)
            confidence = (try? c.decodeIfPresent(PerPlayer<[String: Confidence]>.self, forKey: .confidence))?.mac ?? [:]
            knownIssues = (try? c.decodeIfPresent(PerPlayer<[String: String]>.self, forKey: .knownIssues))?.mac ?? [:]
            listened = (try? c.decodeIfPresent([Emu.Listened].self, forKey: .listened)) ?? []
            release = try? c.decodeIfPresent(Release.self, forKey: .release)
            listed = try? c.decodeIfPresent(String.self, forKey: .listed)
            image = (try? c.decodeIfPresent(String.self, forKey: .image)).flatMap { SafeName.isRelativePath($0) ? $0 : nil }
        }

        /// Whether the Mac app may download and play its .rfm1 build: a build exists and the Mac status allows it.
        public var macDownloadable: Bool { download != nil && (mac.state == .playable || mac.state == .experimental) }
        /// Whether the app can play it at all: its .rfm1 build, or its original package on the emulator.
        public var macPlayable: Bool { macDownloadable || (emu?.macPlayable ?? false) }

        /// the original package as a library entry (`<id>.fwsc`), downloaded from the maker and checked against its hash
        public var packageEntry: CatalogueEntry? {
            guard let em = emu, em.macPlayable, let p = em.package, SafeName.isID(id + CatalogueEntry.packageSuffix) else { return nil }
            let sha = p.sha256.lowercased()
            return CatalogueEntry(id: id + CatalogueEntry.packageSuffix, name: name, version: p.version ?? version, authors: authors,
                                  category: category, tag: tag, about: about, license: p.license ?? license,
                                  source: p.source ?? source, beta: beta, file: "pkg/\(id)-\(sha.prefix(8)).fwsc", sha256: sha,
                                  size: p.size ?? 0, added: download?.added, updated: download?.updated, image: download?.image ?? image,
                                  remoteURL: p.url)
        }
        /// the engine the catalogue recommends on the Mac, among those the app can run here. The catalogue's choice is
        /// made from Apple Silicon measurements; on an Intel Mac the emulator is much slower (a median 1.55x real time
        /// against 3x), so there the .rfm1 build comes first unless the package was measured fast enough on Intel too.
        public var preferredMacEngine: String? {
            let have = (macDownloadable ? ["rfm1"] : []) + ((emu?.macPlayable ?? false) ? ["fm1-emu"] : [])
            #if arch(x86_64)
            if have.count > 1, (emu?.macTested?.intelSpeed ?? 0) < 1.2 { return "rfm1" }
            #endif
            if let p = emu?.preferredMac?.engine, have.contains(p) { return p }
            return have.first
        }
        /// why, for the details pane
        public var preferredMacReason: String? {
            #if arch(x86_64)
            if preferredMacEngine == "rfm1", emu?.preferredMac?.engine == "fm1-emu" {
                return "On an Intel Mac the emulator runs too slowly for this firmware, so its .rfm1 build comes first."
            }
            #endif
            return emu?.preferredMac?.reason
        }
    }

    public static func decode(_ data: Data) throws -> CatalogueV2 {
        let c: CatalogueV2
        do { c = try JSONDecoder().decode(CatalogueV2.self, from: data) } catch { throw PocketError.badCatalogue("v2: \(error)") }
        guard c.schema == 2 else { throw PocketError.badCatalogue("unknown catalogue schema \(c.schema) in catalog-v2.json") }
        return c
    }

    /// The firmware this app downloads and plays, as a schema-1 catalogue (validated: unsafe entries dropped): each
    /// .rfm1 build, and each original package the emulator can run (as `<id>.fwsc`, after the firmware's build).
    public func macCatalogue() throws -> Catalogue {
        var list: [CatalogueEntry] = []
        for e in firmwares {
            if e.macDownloadable, let d = e.download { list.append(d) }
            if let p = e.packageEntry { list.append(p) }
        }
        return try Catalogue(schema: 1, updated: updated, since: since, count: nil, firmwares: list).validated()
    }

    /// The rest: firmware this app cannot play, with why.
    public var notDownloadable: [Entry] { firmwares.filter { !$0.macPlayable } }

    /// For a library entry id: nil when the firmware has only that one, else whether it is the engine the catalogue
    /// does not prefer (true: the alternative, downloaded only when chosen).
    public func alternative(for libraryID: String) -> Bool? {
        let pkg = libraryID.hasSuffix(CatalogueEntry.packageSuffix)
        guard let e = entry(pkg ? String(libraryID.dropLast(CatalogueEntry.packageSuffix.count)) : libraryID),
              e.macDownloadable, e.emu?.macPlayable == true else { return nil }
        return (e.preferredMacEngine == "fm1-emu") != pkg
    }

    /// Fills in what the published catalogue does not have yet from a preview (`emu-preview.json`, bundled in test
    /// builds), only where the Hub version matches, so a stale preview never offers an outdated package: the emu
    /// blocks (ignored once Pocket publishes its own) and the discovery dates (release, listed) an entry lacks.
    public func withPreview(_ data: Data?) -> CatalogueV2 {
        guard let data, let p = try? JSONDecoder().decode(EmuPreview.self, from: data) else { return self }
        // the emulator's blocks only while the published catalogue has none; discovery dates wherever it lacks them
        let emuPublished = firmwares.contains { $0.emu != nil }
        var c = self
        for i in c.firmwares.indices {
            guard let b = p.firmwares[c.firmwares[i].id], b.hubVersion == nil || b.hubVersion == c.firmwares[i].hubVersion else { continue }
            if !emuPublished {
                if let e = b.emu { c.firmwares[i].emu = e }
                if let m = b.confidence?.mac { c.firmwares[i].confidence = m }
                if let m = b.knownIssues?.mac { c.firmwares[i].knownIssues = m }
                if let l = b.listened { c.firmwares[i].listened = l }
            }
            if c.firmwares[i].release == nil, let r = b.release { c.firmwares[i].release = r }
            if c.firmwares[i].listed == nil, let l = b.listed { c.firmwares[i].listed = l }
            if c.firmwares[i].image == nil, let im = b.image, SafeName.isRelativePath(im) { c.firmwares[i].image = im }
        }
        return c
    }
    struct EmuPreview: Decodable {
        struct Item: Decodable {
            var hubVersion: String?
            var emu: Emu?
            var confidence: PerPlayer<[String: Confidence]>?
            var knownIssues: PerPlayer<[String: String]>?
            var listened: [Emu.Listened]?
            var release: Release?
            var listed: String?
            var image: String?
        }
        var firmwares: [String: Item]
    }

    public func entry(_ id: String) -> Entry? { firmwares.first { $0.id == id } }
}

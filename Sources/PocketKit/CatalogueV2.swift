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
        }
        public var state: State
        public var reason: String?
        public var tested: Test?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // a state this app does not know yet is treated as "source-only": shown, never downloaded
            state = (try? c.decode(State.self, forKey: .state)) ?? .sourceOnly
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            tested = try? c.decodeIfPresent(Test.self, forKey: .tested)
        }
        public init(state: State, reason: String? = nil, tested: Test? = nil) {
            self.state = state; self.reason = reason; self.tested = tested
        }
        enum CodingKeys: String, CodingKey { case state, reason, tested }
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

        enum CodingKeys: String, CodingKey {
            case id, name, version, authors, makers, category, tag, about, license, source, beta, status, restriction, provenance, file, sha256
        }
        struct Statuses: Decodable { var web: Status?; var mac: Status? }
        struct Provenance: Decodable {
            struct Hub: Decodable { var url: String? }
            var hub: Hub?
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
            authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
            source = try c.decodeIfPresent(String.self, forKey: .source)
            makers = (try? c.decodeIfPresent([Maker].self, forKey: .makers)) ?? authors.map { Maker(name: $0, url: source) }
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
            hubURL = (try? c.decodeIfPresent(Provenance.self, forKey: .provenance))?.hub?.url
            download = c.contains(.file) && c.contains(.sha256) ? try? CatalogueEntry(from: decoder) : nil
        }

        /// Whether the Mac app may download and play it: a build exists and the Mac status allows it.
        public var macDownloadable: Bool { download != nil && (mac.state == .playable || mac.state == .experimental) }
    }

    public static func decode(_ data: Data) throws -> CatalogueV2 {
        let c: CatalogueV2
        do { c = try JSONDecoder().decode(CatalogueV2.self, from: data) } catch { throw PocketError.badCatalogue("v2: \(error)") }
        guard c.schema == 2 else { throw PocketError.badCatalogue("unknown catalogue schema \(c.schema) in catalog-v2.json") }
        return c
    }

    /// The firmware this app downloads and plays, as a schema-1 catalogue (validated: unsafe entries dropped).
    public func macCatalogue() throws -> Catalogue {
        try Catalogue(schema: 1, updated: updated, since: since, count: nil,
                      firmwares: firmwares.filter(\.macDownloadable).compactMap(\.download)).validated()
    }

    /// The rest: firmware this app cannot download, with why.
    public var notDownloadable: [Entry] { firmwares.filter { !$0.macDownloadable } }

    public func entry(_ id: String) -> Entry? { firmwares.first { $0.id == id } }
}

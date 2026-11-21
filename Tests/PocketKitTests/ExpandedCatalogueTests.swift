import Foundation
import XCTest
@testable import PocketKit

/// FM1 Editor's listings and two promotions, on the expanded catalogue FM-1 Pocket Player's pipeline builds from its
/// recorded inputs (fm1-pocket-player, pocket/tests/golden/make_expanded.py: discover.mjs then the emulator layer):
///
///   night 1   159 listing-only entries from FM1 Editor, each with its description in attributedDescription
///   night 2   The Firmware Hub adds KickSide (Pocket id "kickside") with a verified original package, and RemoteFM1FW
///             builds GLITCH ("glitch-ttreu") as "glitchdrums"; catalog.json (frozen for older apps) uses the build's id
///
/// What this app's library code makes of it.
final class ExpandedCatalogueTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    private func v2(_ name: String) throws -> CatalogueV2 { try CatalogueV2.decode(Data(contentsOf: Self.dir.appendingPathComponent(name))) }
    private func isListing(_ e: CatalogueV2.Entry) -> Bool { e.restriction?.code == "listing-only" }

    func testEditorListingsDecodeWithTheirCreditAndAreNeverDownloaded() throws {
        let c = try v2("expanded-v2-night1.json")
        XCTAssertEqual(c.firmwares.count, 444)
        let listings = c.firmwares.filter(isListing)
        XCTAssertEqual(listings.count, 159)
        let mac = try c.macCatalogue()
        let downloads = Set(mac.firmwares.map(\.id))
        let known = Set(c.firmwares.filter { !isListing($0) }.map(\.category))
        for e in listings {
            XCTAssertFalse(e.macPlayable, e.id)
            XCTAssertFalse(downloads.contains(e.id) || downloads.contains(e.id + CatalogueEntry.packageSuffix), e.id)
            XCTAssertNil(e.download, e.id)
            XCTAssertNil(e.emu?.package, e.id)
            XCTAssertEqual(e.mac.state, .sourceOnly, e.id)
            XCTAssertFalse(e.mac.reason?.isEmpty ?? true, "\(e.id) says why it is not here")
            XCTAssertNotNil(e.source, "\(e.id) links to where to get it")
            XCTAssertNil(e.hubURL, "\(e.id): never The Firmware Hub's credit")
            XCTAssertTrue(e.editorURL?.hasPrefix("https://fm1-editor.com/firmware/#") ?? false, e.id)
            XCTAssertEqual(e.about, "", "\(e.id): the Editor's words are never in about, which 0.9.0 shows uncredited")
            let d = try XCTUnwrap(e.attributedDescription, e.id)
            XCTAssertGreaterThan(d.text.count, 50, e.id)
            XCTAssertEqual(d.credit, "Description from FM1 Editor")
            XCTAssertEqual(d.license, "MIT")
            XCTAssertTrue(d.licenseUrl?.hasPrefix("https://github.com/benny-sparra/fm1-dx7-patch-importer/") ?? false)
            XCTAssertEqual(d.copyright, "Copyright (c) 2026 Ben Sparrow")
            XCTAssertEqual(d.url, e.editorURL)
            XCTAssertTrue(known.contains(e.category), "\(e.id): \(e.category) is one of the categories the app already shows")
            XCTAssertEqual(e.listed, "2026-10-07", "\(e.id): backfilled, so New to Library is not flooded")
        }
        XCTAssertEqual(c.editorSource?.license, "MIT")
        XCTAssertEqual(c.editorSource?.copyright, "Copyright (c) 2026 Ben Sparrow")
        XCTAssertEqual(c.attribution?.license, "CC BY 4.0", "the Hub's credit is unchanged")
    }

    func testPromotedFirmwareKeepsItsPocketIDAndBecomesPlayable() throws {
        let n1 = try v2("expanded-v2-night1.json"), n2 = try v2("expanded-v2-night2.json")
        let k = try XCTUnwrap(n2.entry("kickside"))
        XCTAssertNil(n2.entry("kicksidefm"), "no duplicate under the Hub's id")
        XCTAssertNotNil(k.hubURL, "the Hub lists it now, so its credit shows")
        XCTAssertNotNil(k.editorURL, "and the Editor's credit stays")
        XCTAssertEqual(k.attributedDescription?.credit, "Description from FM1 Editor")
        XCTAssertTrue(k.macPlayable, "playable on the Mac through the Hub's verified package")
        XCTAssertEqual(k.packageEntry?.id, "kickside" + CatalogueEntry.packageSuffix)
        XCTAssertTrue(k.packageEntry?.remoteURL?.hasPrefix("https://") ?? false, "downloaded from the maker's release")
        XCTAssertEqual(k.preferredMacEngine, "fm1-emu")
        XCTAssertEqual(k.listed, "2026-10-07", "the day Pocket first listed it")
        let was = try XCTUnwrap(n1.entry("kickside"))
        XCTAssertFalse(was.macPlayable, "on night 1 it was a listing")

        let g = try XCTUnwrap(n2.entry("glitch-ttreu"))
        XCTAssertNil(n2.entry("glitchdrums"))
        XCTAssertEqual(g.aliases, ["glitchdrums"])
        XCTAssertTrue(g.macDownloadable)
        XCTAssertEqual(g.download?.id, "glitch-ttreu")
        XCTAssertEqual(n2.entry("glitch")?.name, "GR!MM", "Pocket's own glitch is untouched")

        let m1 = try n1.macCatalogue(), m2 = try n2.macCatalogue()
        XCTAssertEqual(m2.firmwares.count, m1.firmwares.count + 2, "GLITCH's build and KickSide's package, nothing else")
        XCTAssertTrue(m2.firmwares.contains(where: { $0.id == "glitch-ttreu" }))
        XCTAssertFalse(m2.firmwares.contains(where: { $0.id == "glitchdrums" }))
        for e in m1.firmwares { XCTAssertEqual(m2.firmwares.first(where: { $0.id == e.id }), e, "\(e.id) is unchanged") }
    }

    /// catalog.json uses the .rfm1 build's own id; with the aliases remembered from v2, a sync that falls back to
    /// catalog.json gives the library exactly the same downloads, under the same ids.
    func testCatalogJSONFallbackKeepsPocketIDs() throws {
        let n2 = try v2("expanded-v2-night2.json")
        let v1 = try Catalogue.decode(Data(contentsOf: Self.dir.appendingPathComponent("expanded-v1-night2.json"))).validated()
        XCTAssertTrue(v1.firmwares.contains(where: { $0.id == "glitchdrums" }), "catalog.json keeps the build's own id")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fm1-aliases-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(root: root)
        XCTAssertEqual(FirmwareLibrary.withPocketIDs(v1, paths: paths).firmwares.map(\.id), v1.firmwares.map(\.id), "nothing remembered yet: unchanged")
        FirmwareLibrary.rememberAliases(n2, paths: paths)
        let mapped = FirmwareLibrary.withPocketIDs(v1, paths: paths)
        let builds = try n2.macCatalogue().firmwares.filter { !$0.isPackage }
        XCTAssertEqual(Set(mapped.firmwares.map(\.id)), Set(builds.map(\.id)))
        let g = try XCTUnwrap(mapped.firmwares.first(where: { $0.id == "glitch-ttreu" }))
        XCTAssertEqual(g, builds.first(where: { $0.id == "glitch-ttreu" }), "the same file, size and checksum as v2's")
        // an alias the catalogue later uses as a firmware's own id is forgotten
        var own = n2
        if let i = own.firmwares.firstIndex(where: { $0.id == "glitch-ttreu" }) { own.firmwares[i].id = "glitchdrums"; own.firmwares[i].aliases = [] }
        FirmwareLibrary.rememberAliases(own, paths: paths)
        XCTAssertTrue(FirmwareLibrary.withPocketIDs(v1, paths: paths).firmwares.contains(where: { $0.id == "glitchdrums" }))
    }
}

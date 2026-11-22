import AppKit
import XCTest
@testable import FM1Pocket
@testable import PocketKit

/// The expanded catalogue in the app's own library model (Tests/Fixtures/expanded-*.json, from FM-1 Pocket Player's
/// pipeline): FM1 Editor's listings under More Firmware with their credited descriptions, categories and links,
/// favourites that follow a firmware from listing to playable, and the credits.
@MainActor
final class ExpandedLibraryTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// the library as the app shows it after a sync of this catalogue (the cached v2 drives it; nothing downloaded)
    private func library(_ fixture: String) async throws -> (FirmwareLibrary.Snapshot, items: [FM1Pocket.LibraryItem], more: [FM1Pocket.LibraryItem], paths: LibraryPaths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fm1-expanded-\(UUID().uuidString)", isDirectory: true)
        let paths = LibraryPaths(root: root)
        try FileManager.default.createDirectory(at: paths.managed, withIntermediateDirectories: true)
        try Data(contentsOf: Self.dir.appendingPathComponent(fixture)).write(to: paths.catalogueV2)
        let lib = FirmwareLibrary(paths: paths, base: URL(string: "https://pocket.test/data/")!)
        let snap = await lib.snapshot()
        let m = LibraryModel.merged(snap, choices: [:], base: lib.base, paths: paths, builtin: nil)
        return (snap, m.items, snap.more.map { FM1Pocket.LibraryItem(listed: $0) }, paths)
    }

    func testEditorListingsUnderMoreFirmwareWithCreditedDescriptionsCategoriesAndLinks() async throws {
        let (snap, items, more, _) = try await library("expanded-v2-night1.json")
        XCTAssertEqual(snap.feed, "v2")
        XCTAssertEqual(snap.editorSource?.license, "MIT")
        let listings = more.filter { $0.editorURL != nil && $0.hubURL == nil }
        XCTAssertEqual(listings.count, 159)
        XCTAssertTrue(items.allSatisfy { !$0.id.hasPrefix("more:") })
        let categories = Set(items.map(\.category))
        for it in listings {
            XCTAssertTrue(it.isListedOnly, it.id)
            XCTAssertFalse(it.canPlay, it.id)
            XCTAssertEqual(it.compatibilityText, "Not playable in this app")
            XCTAssertEqual(it.stateTag, "SOURCE ONLY")
            XCTAssertFalse(it.macReason?.isEmpty ?? true, "\(it.id) says why")
            XCTAssertNotNil(it.sourceURL, "\(it.id): Open Source Page")
            XCTAssertEqual(it.about, "")
            XCTAssertEqual(it.attributed?.credit, "Description from FM1 Editor", it.id)
            XCTAssertTrue(categories.contains(it.category), "\(it.id): \(it.category)")
            XCTAssertFalse(it.isNew, "\(it.id): the first import is not New to Library")
        }
        // the details pane shows the description with its credit; search finds words in it
        let k = try XCTUnwrap(more.first(where: { $0.id == "more:kickside" }))
        XCTAssertEqual(k.name, "KickSide")
        XCTAssertEqual(k.category, "Chords")
        XCTAssertTrue(k.attributed?.text.hasPrefix("A play-along firmware") ?? false)
        XCTAssertEqual(k.editorURL, "https://fm1-editor.com/firmware/#kickside")
        XCTAssertEqual(k.sourceURL, "https://github.com/kjs4discovery/kicksidesidekick")
        XCTAssertTrue(LibrarySearch.matches("ukulele", fields: k.searchFields))
        let tool = try XCTUnwrap(more.first(where: { $0.id == "more:midi-processor" }))
        XCTAssertEqual(tool.tag, "Tool or utility")
        XCTAssertEqual(tool.category, "Other")
        let shrub = try XCTUnwrap(more.first(where: { $0.id == "more:shrub" }))
        XCTAssertEqual(shrub.sourceURL, "https://shrub.audio/editor/install", "no repository: the maker's install page")
    }

    func testPromotedFirmwareIsPlayableUnderTheSameIDAndKeepsItsFavourite() async throws {
        let before = try await library("expanded-v2-night1.json")
        let after = try await library("expanded-v2-night2.json")
        XCTAssertNotNil(before.more.first(where: { $0.id == "more:kickside" }))
        // KickSide: a listing on night 1, playable on night 2 (its original package), same firmware
        let k = try XCTUnwrap(after.items.first(where: { $0.id == "cat:kickside" }))
        XCTAssertTrue(k.canPlay)
        XCTAssertEqual(k.engine, "fm1-emu")
        XCTAssertNotNil(k.hubURL, "the Hub lists it now: its credit shows")
        XCTAssertNotNil(k.editorURL, "and Listed by FM1 Editor stays")
        XCTAssertEqual(k.attributed?.credit, "Description from FM1 Editor")
        XCTAssertNil(after.more.first(where: { $0.id == "more:kickside" }), "no longer under More Firmware")
        XCTAssertNil(after.items.first(where: { $0.id == "cat:kicksidefm" }))
        // GLITCH: a listing on night 1, its .rfm1 build on night 2, under its Pocket id
        let g = try XCTUnwrap(after.items.first(where: { $0.id == "cat:glitch-ttreu" }))
        XCTAssertEqual(g.engine, "rfm1")
        XCTAssertNil(after.items.first(where: { $0.id == "cat:glitchdrums" }))
        XCTAssertEqual(after.items.first(where: { $0.id == "cat:glitch" })?.name, "GR!MM")

        // favourited as a listing (the menu, or the details pane), it is still a favourite once playable
        let store = FavouritesStore(paths: before.paths)
        try store.save(["more:kickside", "more:glitch-ttreu"])
        let favs = store.load()
        XCTAssertTrue(LibraryModel.isFavourite("cat:kickside", in: favs))
        XCTAssertTrue(LibraryModel.isFavourite("cat:glitch-ttreu", in: favs))
        XCTAssertFalse(LibraryModel.isFavourite("cat:glitch", in: favs), "GR!MM is another firmware")
        XCTAssertFalse(LibraryModel.isFavourite("cat:kicksidefm", in: favs))
        XCTAssertEqual(FM1Pocket.LibraryItem.firmwareKey("more:kickside"), FM1Pocket.LibraryItem.firmwareKey("cat:kickside"))
        XCTAssertEqual(FM1Pocket.LibraryItem.firmwareKey("builtin:h1"), "builtin:h1")
        XCTAssertEqual(FM1Pocket.LibraryItem.firmwareKey("cat:kickside.fwsc"), "cat:kickside.fwsc")
    }

    func testTheExistingLibraryIsUnchangedByTheListings() async throws {
        // the downloadable library is the same with or without FM1 Editor's listings: only More Firmware grows
        let n1 = try await library("expanded-v2-night1.json")
        let dry = try CatalogueV2.decode(Data(contentsOf: Self.dir.appendingPathComponent("expanded-v2-night1.json")))
        let withoutEditor = dry.firmwares.filter { $0.restriction?.code != "listing-only" }
        XCTAssertEqual(n1.items.count, Set(withoutEditor.filter(\.macPlayable).map(\.id)).count)
        XCTAssertEqual(n1.more.count, withoutEditor.filter { !$0.macPlayable }.count + 159)
    }

    func testAboutWindowCreditsFM1EditorWithItsLicence() throws {
        let src = CatalogueV2.Source(name: "FM1 Editor", url: "https://fm1-editor.com/firmware/", credit: "Listed by FM1 Editor", license: "MIT",
                                     licenseUrl: "https://github.com/benny-sparra/fm1-dx7-patch-importer/blob/c017be1/LICENSE",
                                     copyright: "Copyright (c) 2026 Ben Sparrow")
        let with = AboutPanel.credits(nil, editor: src).string
        XCTAssertTrue(with.contains("FM1 Editor – fm1-editor.com"))
        XCTAssertTrue(with.contains("Copyright (c) 2026 Ben Sparrow, licensed MIT"))
        XCTAssertTrue(with.contains("The Firmware Hub"), "the Hub's credit is still there")
        XCTAssertFalse(AboutPanel.credits(nil).string.contains("FM1 Editor"), "no Editor credit when the catalogue has none of its listings")
        let notices = try String(contentsOf: Self.dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("THIRD-PARTY-NOTICES.md"), encoding: .utf8)
        XCTAssertTrue(notices.contains("Copyright (c) 2026 Ben Sparrow"))
        XCTAssertTrue(notices.contains("Permission is hereby granted, free of charge"))
    }
}

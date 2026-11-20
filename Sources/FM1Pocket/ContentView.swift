import AppKit
import PocketKit
import SwiftUI

/// The library window: discover like Finder. A sidebar of sections and categories, the firmware as icons or a
/// sortable list, and the selected firmware's details. Playing opens the separate player window.
struct ContentView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var player: PlayerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            Browser()
                .navigationSplitViewColumnWidth(min: 360, ideal: 560)
        } detail: {
            if let item = library.item(library.selection) {
                DetailView(item: item)
            } else {
                ContentUnavailableView("No Firmware Selected", systemImage: "square.dashed",
                                       description: Text("Select a firmware to see its details."))
            }
        }
        .onChange(of: player.showRequest) { _, _ in openWindow(id: "player") }
        .background(WindowFrameKeeper(name: "FM1Pocket.Library"))
        .alert("Something went wrong", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: {
            Text(player.error ?? "")
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        List(selection: Binding(get: { library.section }, set: { if let s = $0 { library.section = s } })) {
            Section("Library") {
                row(.all, "square.grid.2x2")
                row(.favourites, "star")
                row(.recent, "clock")
                row(.new, "sparkles")
                if !library.withdrawnItems.isEmpty { row(.withdrawn, "archivebox") }
                if library.count(.experimental) > 0 { row(.experimental, "flask") }
                if !library.moreItems.isEmpty { row(.more, "books.vertical") }
            }
            Section("Categories") {
                ForEach(library.categoryNames, id: \.self) { c in row(.category(c), icon(for: c)) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(library.status)
                    .lineLimit(4)
                if let a = library.attribution { HubCredit(attribution: a) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func row(_ s: SidebarItem, _ symbol: String) -> some View {
        Label(s.title, systemImage: symbol)
            .badge(library.count(s))
            .tag(s)
    }

    private func icon(for category: String) -> String {
        let c = category.lowercased()
        if c.contains("groove") { return "square.grid.3x3.square" }
        if c.contains("drum") { return "circle.grid.2x2" }
        if c.contains("synth") { return "waveform" }
        if c.contains("seq") { return "list.number" }
        if c.contains("loop") || c.contains("sampl") { return "repeat" }
        if c.contains("game") || c.contains("toy") { return "gamecontroller" }
        if c.contains("tool") || c.contains("util") { return "wrench.and.screwdriver" }
        return "folder"
    }
}

// MARK: - Browser: icons or list

private struct Browser: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        let items = library.visible
        Group {
            if items.isEmpty {
                empty
            } else if library.viewMode == .icons {
                IconGrid(items: items)
            } else {
                FirmwareTable(items: items)
            }
        }
        .navigationTitle(library.section.title)
        .navigationSubtitle("\(items.count) firmware")
        .searchable(text: $library.search, placement: .toolbar, prompt: "Search firmware, authors, sounds")
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $library.viewMode) {
                    Label("Icons", systemImage: "square.grid.2x2").tag(ViewMode.icons)
                    Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                .help("Show as icons or as a list")
                if library.viewMode == .icons {
                    Menu {
                        Picker("Sort By", selection: $library.sort) {
                            ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort By", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort by")
                }
                Button { library.refresh() } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .disabled(library.isRefreshing)
                .help("Check for firmware updates")
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if !library.search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: library.search)
        } else {
            switch library.section {
            case .favourites:
                ContentUnavailableView("No Favourites Yet", systemImage: "star",
                                       description: Text("Click the star on a firmware to keep it here."))
            case .recent:
                ContentUnavailableView("Nothing Played Yet", systemImage: "clock",
                                       description: Text("Firmware you play shows up here."))
            case .new:
                ContentUnavailableView("Nothing New", systemImage: "sparkles",
                                       description: Text("No firmware was added in the last \(NewBadge.days) days."))
            default:
                ContentUnavailableView("No Firmware", systemImage: "square.dashed",
                                       description: Text("The catalogue has not downloaded yet. Check your connection, then choose Check for Firmware Updates."))
            }
        }
    }
}

private struct IconGrid: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var player: PlayerModel
    let items: [LibraryItem]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)], spacing: 16) {
                    ForEach(items) { item in
                        FirmwareCard(item: item, selected: library.selection == item.id,
                                     playing: player.playingID == item.id, favourite: library.isFavourite(item))
                            .id(item.id)
                            .contentShape(Rectangle())
                            // one click selects; the second click of a double-click plays (as Finder opens)
                            .onTapGesture {
                                library.select(item.id)
                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open(item) }
                            }
                            .contextMenu { FirmwareMenu(item: item) }
                    }
                }
                .padding(16)
            }
            .onAppear { if let s = library.selection { proxy.scrollTo(s) } }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// double-click: play, or (for firmware this app cannot play) open its source page
    private func open(_ item: LibraryItem) {
        if item.canPlay { player.play(item, library: library) }
        else if let s = item.sourceURL ?? item.hubURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

/// The Firmware Hub's credit, as its terms ask: the credit line linked to the Hub, the licence linked, and what
/// FM-1 Pocket changed.
struct HubCredit: View {
    let attribution: CatalogueV2.Attribution

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let u = URL(string: attribution.url) { Link(attribution.text, destination: u) } else { Text(attribution.text) }
            HStack(spacing: 3) {
                Text("Licence:")
                if let l = attribution.licenseUrl, let u = URL(string: l) { Link(attribution.license, destination: u) }
                else { Text(attribution.license) }
            }
        }
        .help(attribution.changes ?? "")
    }
}

/// The maker credits, each linked to their repository when known.
struct MakerLinks: View {
    let makers: [CatalogueV2.Maker]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(makers.enumerated()), id: \.offset) { i, m in
                if let s = m.url, let u = URL(string: s) { Link(m.name, destination: u) } else { Text(m.name) }
                if i < makers.count - 1 { Text("·").foregroundStyle(.secondary) }
            }
        }
    }
}

/// One firmware in the icon view: its screen, name, version and author, and badges.
private struct FirmwareCard: View {
    let item: LibraryItem
    let selected: Bool
    let playing: Bool
    let favourite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Thumbnail(item: item)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) { StatusBadge(item: item, playing: playing).padding(5) }
                .overlay(alignment: .topLeading) {
                    if favourite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .padding(5)
                    }
                }
            HStack(spacing: 4) {
                Text(item.name).font(.headline).lineLimit(1)
                if item.isNew { Tag(text: "NEW", color: .green) }
                if item.isBeta { Tag(text: "BETA", color: .orange) }
                if let t = item.stateTag { Tag(text: t, color: .secondary).help(item.macReason ?? "") }
            }
            Text(item.byline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// Download state and "playing" in a corner of the screenshot.
struct StatusBadge: View {
    let item: LibraryItem
    let playing: Bool

    private var shows: Bool { playing || item.downloading || item.download != .installed }

    var body: some View {
        Group {
            if playing {
                Image(systemName: "speaker.wave.2.fill")
            } else if item.downloading {
                ProgressView().controlSize(.mini)
            } else if item.lastError != nil && item.download != .installed {
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                switch item.download {
                case .installed: EmptyView()
                case .olderInstalled: Image(systemName: "arrow.down.circle.dotted")
                case .notDownloaded: Image(systemName: "arrow.down.circle")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(shows ? 4 : 0)
        .background(Color.black.opacity(shows ? 0.5 : 0), in: Circle())
        .help(playing ? "Playing" : item.downloadText)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
    }
}

private struct FirmwareTable: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var player: PlayerModel
    let items: [LibraryItem]
    @State private var order: [KeyPathComparator<LibraryItem>] = []

    var body: some View {
        let rows = order.isEmpty ? items : items.sorted(using: order)
        Table(rows, selection: Binding(get: { library.selection }, set: { library.select($0) }), sortOrder: $order) {
            TableColumn("★") { (item: LibraryItem) in
                Image(systemName: library.isFavourite(item) ? "star.fill" : "star")
                    .foregroundStyle(library.isFavourite(item) ? Color.yellow : Color.secondary.opacity(0.4))
                    .onTapGesture { library.toggleFavourite(item) }
                    .help(library.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites")
            }
            .width(22)
            TableColumn("Name", value: \.name) { (item: LibraryItem) in
                HStack(spacing: 6) {
                    Thumbnail(item: item).frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(item.name)
                    if item.isNew { Tag(text: "NEW", color: .green) }
                    if item.isBeta { Tag(text: "BETA", color: .orange) }
                    if let t = item.stateTag { Tag(text: t, color: .secondary).help(item.macReason ?? "") }
                    if player.playingID == item.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Version", value: \.version).width(min: 50, ideal: 70)
            TableColumn("Author", value: \.authors).width(min: 80, ideal: 150)
            TableColumn("Category", value: \.category).width(min: 70, ideal: 100)
            TableColumn("Status", value: \.statusText).width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: LibraryItem.ID.self) { ids in
            if let id = ids.first, let item = library.item(id) { FirmwareMenu(item: item) }
        } primaryAction: { ids in
            guard let id = ids.first, let item = library.item(id) else { return }
            if item.canPlay { player.play(item, library: library) }
            else if let s = item.sourceURL ?? item.hubURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        }
    }
}

/// The right-click menu for a firmware.
struct FirmwareMenu: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var player: PlayerModel
    let item: LibraryItem

    var body: some View {
        if item.canPlay {
            Button(player.playingID == item.id ? "Restart" : "Play") { player.play(item, library: library) }
            if player.playingID == item.id { Button("Stop") { player.stop() } }
            Divider()
            Button(library.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites") { library.toggleFavourite(item) }
            if !item.isBuiltin && !item.isWithdrawn && item.download != .installed && !item.downloading {
                Button("Download Now") { library.download(item) }
            }
            Divider()
        }
        if let s = item.sourceURL, let u = URL(string: s) {
            Button("Open Source Page") { NSWorkspace.shared.open(u) }
        }
        if let s = item.hubURL, let u = URL(string: s) {
            Button("Open on The Firmware Hub") { NSWorkspace.shared.open(u) }
        }
    }
}

/// A firmware's screen: the cached screenshot (works offline), else the online one, else a placeholder.
struct Thumbnail: View {
    let item: LibraryItem

    var body: some View {
        if let file = item.screenshotFile, let img = ThumbnailCache.shared.image(file) {
            Image(nsImage: img).resizable().interpolation(.none)
        } else if let url = item.imageURL {
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().interpolation(.none) } else { placeholder }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.black
            Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
        }
    }
}

/// Keeps decoded screenshots in memory so scrolling the icon view does not re-read files.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(_ url: URL) -> NSImage? {
        if let i = cache.object(forKey: url as NSURL) { return i }
        guard let i = NSImage(contentsOf: url) else { return nil }
        cache.setObject(i, forKey: url as NSURL)
        return i
    }
}

// MARK: - Details

private struct DetailView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var player: PlayerModel
    @Environment(\.openWindow) private var openWindow
    let item: LibraryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Thumbnail(item: item)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 2, y: 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.title).bold().textSelection(.enabled)
                        if item.isNew { Tag(text: "NEW", color: .green) }
                        if item.isBeta { Tag(text: "BETA", color: .orange) }
                    }
                    if !item.tag.isEmpty { Text(item.tag).font(.title3).foregroundStyle(.secondary) }
                }

                if item.isListedOnly {
                    notAvailable
                } else {
                    controls
                }

                if let r = item.macReason, item.isExperimental {
                    Label(r, systemImage: "flask")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.isWithdrawn {
                    Label("Pocket no longer lists this firmware. Your downloaded copy and saved settings are kept.",
                          systemImage: "archivebox")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !item.about.isEmpty {
                    Text(item.about).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }

                facts
                    .font(.callout)

                if item.hubURL != nil, let a = library.attribution {
                    HubCredit(attribution: a).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// for firmware this app cannot play: why, and where to get it
    @ViewBuilder private var notAvailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.macReason ?? "This firmware is not available in this app.", systemImage: "info.circle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let s = item.sourceURL, let u = URL(string: s) {
                    Button { NSWorkspace.shared.open(u) } label: { Label("Open Source Page", systemImage: "arrow.up.right.square") }
                        .keyboardShortcut(.defaultAction)
                }
                if let s = item.hubURL, let u = URL(string: s) {
                    Button("Open on The Firmware Hub") { NSWorkspace.shared.open(u) }
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
                HStack(spacing: 8) {
                    if player.playingID == item.id {
                        Button { openWindow(id: "player") } label: { Label("Show Player", systemImage: "pianokeys") }
                            .keyboardShortcut(.defaultAction)
                        Button("Stop") { player.stop() }
                    } else {
                        Button { player.play(item, library: library) } label: { Label("Play", systemImage: "play.fill") }
                            .keyboardShortcut(.defaultAction)
                            .disabled(player.loadingID != nil)
                    }
                    Button { library.toggleFavourite(item) } label: {
                        Label(library.isFavourite(item) ? "Favourite" : "Add to Favourites",
                              systemImage: library.isFavourite(item) ? "star.fill" : "star")
                    }
                    .help(library.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites")
                    if player.loadingID == item.id { ProgressView().controlSize(.small) }
                }
    }

    @ViewBuilder private var facts: some View {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    fact("Version", item.version)
                    if item.makers.isEmpty {
                        fact("Author", item.authors)
                    } else {
                        GridRow {
                            Text(item.makers.count == 1 ? "Maker" : "Makers").foregroundStyle(.secondary)
                            MakerLinks(makers: item.makers)
                        }
                    }
                    fact("Category", item.category)
                    fact("Licence", item.license)
                    if item.size > 0 {
                        fact("Size", ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    }
                    fact("Added", day(item.added))
                    if item.updated != item.added { fact("Updated", day(item.updated)) }
                    fact("Download", item.downloadText)
                    engineRow
                    if let st = item.macState, !item.isListedOnly { fact("On this Mac", compatibility(st)) }
                    testRows
                    if let p = item.previousVersion { fact("Previous", "Version \(p) is kept too") }
                    if let r = library.recent[item.id] {
                        fact("Last played", RelativeDateTimeFormatter().localizedString(for: r, relativeTo: Date()))
                    }
                    if let s = item.sourceURL, let u = URL(string: s) {
                        GridRow {
                            Text("Source").foregroundStyle(.secondary)
                            Link(s, destination: u).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
    }

    private func compatibility(_ st: CatalogueV2.Status.State) -> String {
        let how: String
        switch item.verification {
        case .macos: how = "tested individually on macOS"
        case .representative: how = "tested with this app's engine on Linux; a sample of firmware was verified on macOS"
        case .linux: how = "tested with this app's engine on Linux only"
        default: how = "not tested yet"
        }
        switch st {
        case .playable: return "Playable: " + how
        case .experimental: return (item.mayStutter ? "Experimental, may stutter: " : "Experimental: ") + how
        case .unsupported: return "Not supported: " + how
        case .sourceOnly: return "Source only"
        case .unavailable: return "Not available"
        }
    }

    /// the engine line: which engine plays it, and a quiet switch where both can
    @ViewBuilder private var engineRow: some View {
        if item.engines.count > 1 {
            GridRow {
                Text("Engine").foregroundStyle(.secondary)
                Menu {
                    ForEach(item.engines, id: \.self) { e in
                        Button {
                            let replay = player.playingID == item.id
                            library.setEngine(e, for: item)
                            if replay {
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    if let next = library.item(item.id) { player.play(next, library: library) }
                                }
                            }
                        } label: {
                            Text(LibraryItem.engineName(e) + (e == item.preferredEngine ? " (recommended)" : ""))
                        }
                        .disabled(e == item.engine)
                    }
                } label: {
                    Text(LibraryItem.engineName(item.engine) + (item.engine == item.preferredEngine ? "" : " (your choice)"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help((item.preferredReason ?? "") + " Each engine keeps its own saved settings.")
            }
        } else if item.engine == "fm1-emu" {
            fact("Engine", LibraryItem.engineName(item.engine))
        }
    }

    /// automated checks and listening tests, kept apart
    @ViewBuilder private var testRows: some View {
        if item.engine == "fm1-emu", let t = item.emuTested {
            fact("Automated check", [t.machine.map { "on " + $0 }, t.speed.map { String(format: "%.1fx real time", $0) },
                                     t.engine].compactMap { $0 }.joined(separator: ", ") + " (a scripted boot check; nobody listened)")
        }
        if item.engine == "fm1-emu" || !item.listened.isEmpty {
            let mine = item.listened.filter { ($0.engine ?? "fm1-emu") == item.engine }
            fact("Listening test", mine.isEmpty ? "None recorded yet" :
                 mine.map { [$0.verdict, $0.who, $0.date, $0.machine].compactMap { $0 }.joined(separator: ", ") }.joined(separator: "; "))
        }
    }

    private func day(_ s: String?) -> String {
        guard let d = NewBadge.date(s) else { return "" }
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none)
    }

    @ViewBuilder private func fact(_ k: String, _ v: String) -> some View {
        if !v.isEmpty {
            GridRow {
                Text(k).foregroundStyle(.secondary)
                Text(v).textSelection(.enabled)
            }
        }
    }
}

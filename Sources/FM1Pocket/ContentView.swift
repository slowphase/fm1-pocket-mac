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
        .safeAreaInset(edge: .bottom) { LibraryFooter() }
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
                Menu {
                    Picker("Sort By", selection: $library.sort) {
                        ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(library.sort.title, systemImage: "arrow.up.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("Sort by latest release, name, author or category")
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
                ContentUnavailableView("Nothing New to the Library", systemImage: "sparkles",
                                       description: Text("No firmware joined the library in the last \(NewBadge.days) days."))
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
            NameWithTags(item: item).font(.headline)
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
            .lineLimit(1)
            .fixedSize()   // a badge is never cut short or wrapped
    }
}

/// A firmware's name with its badges. Badges stay whole: when space runs short the name shortens first, then the
/// less important badges step aside (compatibility first, then BETA, then NEW), and the name always keeps some room.
struct NameWithTags: View {
    let item: LibraryItem

    private struct Info: Identifiable { let text: String; let color: Color; let help: String; var id: String { text } }

    private var tags: [Info] {
        var t: [Info] = []
        if let s = item.stateTag { t.append(Info(text: s, color: .secondary, help: item.macReason ?? "")) }
        if item.isBeta { t.append(Info(text: "BETA", color: .orange, help: "")) }
        if item.isNew { t.append(Info(text: "NEW", color: .green, help: "New to Library: first listed in the last \(NewBadge.days) days")) }
        return t
    }

    var body: some View {
        let all = tags
        ViewThatFits(in: .horizontal) {
            // everything at its natural size (no padding after a short name)
            HStack(spacing: 4) { Text(item.name).lineLimit(1).fixedSize(); if !all.isEmpty { row(all) } }
            // otherwise the name shortens, keeping at least a little room, and badges step aside as needed
            if !all.isEmpty { HStack(spacing: 4) { shortName; row(all) } }
            if all.count > 2 { HStack(spacing: 4) { shortName; row(Array(all.prefix(2))) } }
            if all.count > 1 { HStack(spacing: 4) { shortName; row(Array(all.prefix(1))) } }
            shortName
        }
        .help(item.name)
    }

    /// counts as 44 points wide when choosing what fits, then takes whatever room is left
    private var shortName: some View {
        Text(item.name).lineLimit(1).truncationMode(.tail).frame(minWidth: 44, idealWidth: 44, maxWidth: .infinity, alignment: .leading)
    }

    // shown in reading order: NEW, BETA, then compatibility
    private func row(_ t: [Info]) -> some View {
        HStack(spacing: 4) {
            ForEach(t.reversed()) { x in Tag(text: x.text, color: x.color).help(x.help) }
        }
        .fixedSize()
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
                    NameWithTags(item: item)
                    if player.playingID == item.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Version", value: \.version).width(min: 50, ideal: 70)
            TableColumn("Author", value: \.authors).width(min: 80, ideal: 150)
            TableColumn("Category", value: \.category).width(min: 70, ideal: 100)
            TableColumn("Released", value: \.releasedSort) { (item: LibraryItem) in
                Text(item.release?.day.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? "")
            }
            .width(min: 80, ideal: 100)
            TableColumn("Status", value: \.statusText).width(min: 90, ideal: 120)
        }
        .onChange(of: library.sort) { order = [] }      // choosing Sort By takes over from a clicked column
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
        } else if item.isListedOnly {
            Button(library.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites") { library.toggleFavourite(item) }
            Divider()
        }
        if let s = item.sourceURL, let u = URL(string: s) {
            Button("Open Source Page") { NSWorkspace.shared.open(u) }
        }
        if let s = item.hubURL, let u = URL(string: s) {
            Button("Open on The Firmware Hub") { NSWorkspace.shared.open(u) }
        }
        if let s = item.editorURL, let u = URL(string: s) {
            Button("Open on FM1 Editor") { NSWorkspace.shared.open(u) }
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

    private var placeholder: some View { FirmwareTile(item: item) }
}

/// For a firmware without a picture: its name (and maker) on a steady colour of its own, the same as the web
/// player's tile, so every firmware is recognisable at a glance.
struct FirmwareTile: View {
    let item: LibraryItem

    /// the web player's hsl(h, 35%, 30%), with h from the same hash of the firmware's id
    static func colour(_ id: String) -> Color {
        var h: UInt32 = 0
        for c in id.unicodeScalars { h = h &* 31 &+ c.value }
        return Color(hue: Double(h % 360) / 360, saturation: 0.519, brightness: 0.405)
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack {
                Self.colour(item.id.hasPrefix("cat:") || item.id.hasPrefix("more:") ? String(item.id.split(separator: ":", maxSplits: 1).last ?? "") : item.id)
                if w < 48 {
                    Text(initials).font(.system(size: max(8, w * 0.42), weight: .bold, design: .monospaced))
                } else {
                    VStack(spacing: w * 0.04) {
                        Text(item.name)
                            .font(.system(size: w * 0.12, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.5)
                        if w > 90, !item.authors.isEmpty {
                            Text(item.authors)
                                .font(.system(size: w * 0.06, design: .monospaced))
                                .opacity(0.7)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                    .padding(w * 0.08)
                }
            }
            .foregroundStyle(Color(white: 0.95))
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let s = item.name.filter { $0.isLetter || $0.isNumber }
        return String(s.prefix(2)).uppercased().isEmpty ? "?" : String(s.prefix(2)).uppercased()
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
    /// collapsed by default: the main pane is for choosing and playing firmware, this is for the curious
    @AppStorage("details.technical") private var showTechnical = false

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
                        if item.isNew { Tag(text: "NEW", color: .green).help("New to Library: first listed in the last \(NewBadge.days) days") }
                        if item.isBeta { Tag(text: "BETA", color: .orange) }
                    }
                    if !item.tag.isEmpty { Text(item.tag).font(.title3).foregroundStyle(.secondary) }
                }

                if item.isListedOnly {
                    notAvailable
                } else {
                    controls
                }

                if item.isWithdrawn {
                    Label("Pocket no longer lists this firmware. Your downloaded copy and saved settings are kept.",
                          systemImage: "archivebox")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !item.about.isEmpty {
                    Text(item.about).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else if let d = item.attributed {
                    // another source's description: never without its credit and licence
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        DescriptionCredit(description: d).font(.caption).foregroundStyle(.secondary)
                    }
                }

                facts
                    .font(.callout)

                if !item.isBuiltin {
                    DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                        technical
                            .font(.callout)
                            .padding(.top, 4)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if item.hubURL != nil, let a = library.attribution {
                    HubCredit(attribution: a).font(.caption).foregroundStyle(.secondary)
                }
                if let s = item.editorURL, let u = URL(string: s) {
                    Link("Listed by FM1 Editor", destination: u).font(.caption).foregroundStyle(.secondary)
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
                // a listed firmware can be a favourite too (it stays one if it becomes playable): a small star here
                Button { library.toggleFavourite(item) } label: {
                    Image(systemName: library.isFavourite(item) ? "star.fill" : "star")
                }
                .help(library.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites")
                .accessibilityLabel(library.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites")
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

    /// What most people want: who made it, which version, when it came out, whether it plays, which engine, where
    /// its source is.
    @ViewBuilder private var facts: some View {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    if item.makers.isEmpty {
                        fact("Maker", item.authors)
                    } else {
                        GridRow {
                            Text(item.makers.count == 1 ? "Maker" : "Makers").foregroundStyle(.secondary)
                            MakerLinks(makers: item.makers)
                        }
                    }
                    fact("Version", item.version)
                    fact("Released", released)
                    GridRow {
                        Text("Compatibility").foregroundStyle(.secondary)
                        Text(item.compatibilityText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .help("Automated checks: in a scripted test the firmware started, made sound and kept time. "
                                  + "Listened to: a person played it in FM-1 Pocket. Neither means every feature was tried.")
                    }
                    if item.engines.count > 1 { engineRow }
                    if let s = item.sourceURL, let u = URL(string: s) {
                        GridRow {
                            Text("Source").foregroundStyle(.secondary)
                            Link(s, destination: u).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
    }

    /// Everything else, kept for those who want it: licence, size, files, the automated checks and the listening
    /// tests behind the Compatibility line, engine details.
    @ViewBuilder private var technical: some View {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    fact("Category", item.category)
                    fact("Licence", item.license)
                    if item.size > 0 {
                        fact("Size", ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    }
                    fact("Download", item.downloadText)
                    if let p = item.previousVersion { fact("Previous", "Version \(p) is kept too") }
                    if !item.isPackage && !item.isListedOnly {
                        fact("Engine", LibraryItem.engineName(item.engine) + (item.engines.count > 1 ? (item.engine == item.preferredEngine ? " (recommended)" : " (your choice)") : ""))
                    }
                    if item.engines.count > 1, let r = item.preferredReason { fact("Why recommended", r) }
                    if let c = item.confidence, c.level == .knownIssue, let n = c.note { fact("Known issue", n) }
                    fact("Automated checks", automatedText)
                    if !item.isPackage && !item.isListedOnly {
                        fact("Listening tests", item.listened.isEmpty ? "None for this file yet" :
                             item.listened.map(listeningText).joined(separator: "\n"))
                    }
                    if let r = item.release, let src = r.source { fact("Release date from", src) }
                    if let r = library.recent[item.id] {
                        fact("Last played", RelativeDateTimeFormatter().localizedString(for: r, relativeTo: Date()))
                    }
                }
    }

    /// what the automated checks did, and where: GitHub's test machines, never the user's Mac
    private var automatedText: String {
        if item.isPackage || item.isListedOnly { return "" }
        var parts: [String] = []
        if item.engine == "fm1-emu", let t = item.emuTested {
            var line = (t.machine?.contains("Darwin") ?? false) ? "Run on GitHub's macOS test machine (Apple Silicon)" : "Run on a GitHub test machine"
            line += ": started, made sound"
            if let sp = t.speed { line += String(format: ", %.1fx real time", sp) }
            if let e = t.engine { line += " (\(e.replacingOccurrences(of: "@", with: " ")))" }
            parts.append(line)
        } else {
            switch item.verification {
            case .macos: parts.append("Run individually with this engine on GitHub's macOS test machine")
            case .representative: parts.append("Run with this engine on GitHub's Linux test machine; a sample of firmware was also run on macOS")
            case .linux: parts.append("Run with this engine on GitHub's Linux test machine")
            default: break
            }
        }
        if let r = item.macReason, item.isExperimental { parts.append(r) }
        return parts.joined(separator: "\n")
    }

    private func listeningText(_ t: CatalogueV2.Emu.Listened) -> String {
        let day = NewBadge.date(t.date).map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? (t.date ?? "")
        let who = [t.who, t.machine, t.app].compactMap { $0 }.joined(separator: ", ")
        return "\(day): \(t.verdict ?? "")" + (who.isEmpty ? "" : " (\(who))")
    }

    /// the engine selector, for a firmware both engines can run
    @ViewBuilder private var engineRow: some View {
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
    }

    /// "13 Nov 2026 (v1.8.2)", plus the version this app plays when it is not the latest release
    private var released: String {
        guard let r = item.release, let d = r.day else { return item.isBuiltin || item.isPackage ? "" : "Not known" }
        var t = DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none)
        // the release date belongs to the latest version; say so when this app plays an older one
        if let v = r.version, !v.isEmpty, !item.version.isEmpty, v != item.version { t += " (latest version \(v))" }
        return t
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

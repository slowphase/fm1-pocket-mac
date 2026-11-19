import SwiftUI

/// Milestone 1's library: a plain native sidebar of firmware names (grouped by category, searchable) and a detail
/// pane with the catalogue's facts, its screenshot and Play. The finished library is Milestone 2.
struct ContentView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        NavigationSplitView {
            List(selection: $library.selection) {
                ForEach(library.categories, id: \.self) { cat in
                    Section(cat) {
                        ForEach(library.filtered.filter { $0.category == cat }) { item in
                            Row(item: item, playing: player.playingID == item.id, loading: player.loadingID == item.id)
                                .contextMenu {
                                    Button("Play") { player.play(item, library: library) }
                                }
                        }
                    }
                }
            }
            .searchable(text: $library.search, placement: .sidebar, prompt: "Search firmware")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                Text(library.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        } detail: {
            if let item = library.item(library.selection) {
                DetailView(item: item)
            } else {
                Text("Select a firmware").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { library.refresh() } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
                    .disabled(library.isRefreshing)
                    .help("Check for firmware updates")
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: {
            Text(player.error ?? "")
        }
    }
}

private struct Row: View {
    let item: LibraryItem
    let playing: Bool
    let loading: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).fontWeight(playing ? .semibold : .regular)
                Text([item.version, item.authors].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            else if playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
        }
    }
}

private struct DetailView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var player: PlayerModel
    let item: LibraryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if player.playingID == item.id {
                    PlayerView()
                }
                HStack(alignment: .top, spacing: 20) {
                    if player.playingID != item.id {
                        Group {
                            if let url = item.imageURL {
                                AsyncImage(url: url) { phase in
                                    if let img = phase.image { img.resizable().interpolation(.none) }
                                    else { Color.black }
                                }
                            } else {
                                Color.black.overlay(Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary))
                            }
                        }
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name).font(.largeTitle).bold()
                        if !item.tag.isEmpty { Text(item.tag).font(.title3).foregroundStyle(.secondary) }
                        HStack {
                            Button(player.playingID == item.id ? "Restart" : "Play") { player.play(item, library: library) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(player.loadingID != nil)
                            if player.playingID == item.id { Button("Stop") { player.stop() } }
                            if player.loadingID == item.id { ProgressView().controlSize(.small) }
                        }
                        if !item.about.isEmpty { Text(item.about).fixedSize(horizontal: false, vertical: true) }
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            fact("Version", item.version)
                            fact("Author", item.authors)
                            fact("Category", item.category)
                            fact("Licence", item.license)
                            fact("Size", ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                            fact("Downloaded", library.isDownloaded(item) ? "Yes" : "Not yet")
                            if let s = item.sourceURL, let u = URL(string: s) {
                                GridRow {
                                    Text("Source").foregroundStyle(.secondary)
                                    Link(s, destination: u).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

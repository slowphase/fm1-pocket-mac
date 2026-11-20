import AppKit
import SwiftUI

@main
struct FM1PocketApp: App {
    @StateObject private var library = LibraryModel()
    @StateObject private var player = PlayerModel()

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let out = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
            exit(SelfTest.run(writingTo: out))
        }
    }

    var body: some Scene {
        Window("FM-1 Pocket", id: "library") {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { library.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    player.stop()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Firmware Updates…") { library.refresh() }
                Button("Clean Up Old Downloads") { library.cleanUp() }
            }
            SidebarCommands()
            CommandGroup(before: .sidebar) {
                Button("as Icons") { library.viewMode = .icons }.keyboardShortcut("1", modifiers: .command)
                Button("as List") { library.viewMode = .list }.keyboardShortcut("2", modifiers: .command)
                Divider()
            }
            CommandMenu("Firmware") {
                Button("Play") {
                    if let item = library.item(library.selection) { player.play(item, library: library) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(library.selection == nil)
                Button("Stop") { player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(player.playingID == nil)
                Divider()
                Button(library.item(library.selection).map { library.isFavourite($0) } == true ? "Remove from Favourites" : "Add to Favourites") {
                    if let item = library.item(library.selection) { library.toggleFavourite(item) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(library.selection == nil)
                Button("Download Now") {
                    if let item = library.item(library.selection) { library.download(item) }
                }
                .disabled(library.item(library.selection).map { $0.isBuiltin || $0.download == .installed || $0.downloading } ?? true)
                Divider()
                Button("Show All Firmware") { library.section = .all }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Show Favourites") { library.section = .favourites }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Show Recently Played") { library.section = .recent }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // the player: its own window, so the library stays a library (the FM-1 faceplate is Milestone 3)
        Window("Player", id: "player") {
            PlayerWindow()
                .environmentObject(library)
                .environmentObject(player)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The player window: the running firmware. Closing it stops the sound.
struct PlayerWindow: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        Group {
            if player.playingID != nil {
                PlayerView().padding(20)
            } else if player.loadingID != nil {
                ProgressView("Starting…").frame(width: 420, height: 300)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "pianokeys",
                                       description: Text("Choose a firmware in the library and press Play."))
                    .frame(width: 420, height: 300)
            }
        }
        .navigationTitle(player.playingID == nil ? "Player" : player.title)
        .background(WindowFinder { player.playerWindow = $0 })
        .onDisappear { player.stop() }
    }
}

/// Hands back the NSWindow a SwiftUI view lives in.
struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in found(v?.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in found(nsView?.window) }
    }
}
